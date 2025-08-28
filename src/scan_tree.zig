const std = @import("std");
const gitweb = @import("gitweb.zig");
const shared = @import("shared.zig");
const parsing = @import("parsing.zig");

pub const ScanOptions = struct {
    max_depth: u32 = 3,
    follow_symlinks: bool = false,
    exclude_patterns: []const []const u8 = &.{},
    include_hidden: bool = false,
    project_list: ?[]const u8 = null,
    strict_export: ?[]const u8 = null,
};

pub const RepoScanner = struct {
    allocator: std.mem.Allocator,
    repos: std.ArrayList(*gitweb.Repo),
    options: ScanOptions,
    visited_paths: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, options: ScanOptions) RepoScanner {
        return .{
            .allocator = allocator,
            .repos = std.ArrayList(*gitweb.Repo){
                .items = &.{},
                .capacity = 0,
            },
            .options = options,
            .visited_paths = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *RepoScanner) void {
        for (self.repos.items) |repo| {
            repo.deinit();
        }
        self.repos.deinit(self.allocator);
        self.visited_paths.deinit();
    }

    pub fn scanPath(self: *RepoScanner, path: []const u8, depth: u32) !void {
        if (depth > self.options.max_depth) return;

        // Check if we've already visited this path
        const abs_path = try std.fs.realpathAlloc(self.allocator, path);
        defer self.allocator.free(abs_path);

        if (self.visited_paths.contains(abs_path)) return;
        try self.visited_paths.put(abs_path, {});

        // Check if this path should be excluded
        if (try self.shouldExclude(abs_path)) return;

        // Check if this is a git repository
        if (shared.isGitRepository(abs_path)) {
            try self.addRepository(abs_path);
            return; // Don't scan inside repositories
        }

        // Scan subdirectories
        var dir = try std.fs.openDirAbsolute(abs_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Skip hidden directories unless configured to include them
            if (entry.name[0] == '.' and !self.options.include_hidden) {
                continue;
            }

            if (entry.kind != .directory) continue;

            const child_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ abs_path, entry.name });
            defer self.allocator.free(child_path);

            // Check if it's a symlink and whether we should follow it
            const stat = std.fs.statAbsolute(child_path) catch continue;
            if (stat.kind == .sym_link and !self.options.follow_symlinks) {
                continue;
            }

            // Recursively scan
            try self.scanPath(child_path, depth + 1);
        }
    }

    pub fn scanProjectList(self: *RepoScanner, list_file: []const u8) !void {
        const file = try std.fs.openFileAbsolute(list_file, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(content);

        var lines = std.mem.tokenizeAny(u8, content, "\n\r");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Parse project list line (format: path [owner])
            var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
            const repo_path = parts.next() orelse continue;
            const owner = parts.rest();

            const abs_path = if (repo_path[0] == '/')
                try self.allocator.dupe(u8, repo_path)
            else
                try std.fs.realpathAlloc(self.allocator, repo_path);
            defer self.allocator.free(abs_path);

            if (shared.isGitRepository(abs_path)) {
                const repo = try self.addRepository(abs_path);
                if (owner.len > 0 and repo != null) {
                    repo.?.owner = try self.allocator.dupe(u8, owner);
                }
            }
        }
    }

    fn shouldExclude(self: *RepoScanner, path: []const u8) !bool {
        // Check exclude patterns
        for (self.options.exclude_patterns) |pattern| {
            if (matchPattern(path, pattern)) return true;
        }

        // Check for git-daemon-export-ok if strict export is enabled
        if (self.options.strict_export) |export_flag| {
            const export_file = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, export_flag });
            defer self.allocator.free(export_file);

            if (!shared.fileExists(export_file)) {
                return true; // Exclude if export flag doesn't exist
            }
        }

        return false;
    }

    fn addRepository(self: *RepoScanner, path: []const u8) !?*gitweb.Repo {
        // Check if we've already added this repository
        for (self.repos.items) |repo| {
            if (std.mem.eql(u8, repo.path, path)) {
                return null; // Already added
            }
        }

        const repo_info = try shared.getRepoInfo(self.allocator, path);

        const repo = try gitweb.Repo.init(self.allocator);
        repo.path = try self.allocator.dupe(u8, path);
        repo.name = try self.allocator.dupe(u8, repo_info.name);
        repo.desc = try self.allocator.dupe(u8, repo_info.description);

        // Generate URL from path
        const base_name = std.fs.path.basename(path);
        repo.url = if (std.mem.endsWith(u8, base_name, ".git"))
            try self.allocator.dupe(u8, base_name[0 .. base_name.len - 4])
        else
            try self.allocator.dupe(u8, base_name);

        // Read additional configuration from config file
        try self.readRepoConfig(repo, path);

        try self.repos.append(self.allocator, repo);
        return repo;
    }

    fn readRepoConfig(self: *RepoScanner, repo: *gitweb.Repo, repo_path: []const u8) !void {
        // Try to read cgitrc from repository
        const cgitrc_path = try std.fmt.allocPrint(self.allocator, "{s}/cgitrc", .{repo_path});
        defer self.allocator.free(cgitrc_path);

        if (std.fs.openFileAbsolute(cgitrc_path, .{})) |file| {
            defer file.close();

            const content = file.readToEndAlloc(self.allocator, 4096) catch return;
            defer self.allocator.free(content);

            var lines = std.mem.tokenizeAny(u8, content, "\n\r");
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;

                const eq_pos = std.mem.indexOf(u8, trimmed, "=");
                if (eq_pos) |pos| {
                    const key = std.mem.trim(u8, trimmed[0..pos], " \t");
                    var value = std.mem.trim(u8, trimmed[pos + 1 ..], " \t\"");

                    if (std.mem.eql(u8, key, "desc")) {
                        repo.desc = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "owner")) {
                        repo.owner = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "homepage")) {
                        repo.homepage = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "defbranch")) {
                        repo.defbranch = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "section")) {
                        repo.section = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "clone-url")) {
                        repo.clone_url = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "hide")) {
                        repo.hide = parsing.parseBool(value);
                    } else if (std.mem.eql(u8, key, "ignore")) {
                        repo.ignore = parsing.parseBool(value);
                    }
                }
            }
        } else |_| {
            // cgitrc doesn't exist, try git config
            try self.readGitConfig(repo, repo_path);
        }
    }

    fn readGitConfig(self: *RepoScanner, repo: *gitweb.Repo, repo_path: []const u8) !void {
        const config_path = if (shared.isDirectory(try std.fmt.allocPrint(self.allocator, "{s}/.git", .{repo_path})))
            try std.fmt.allocPrint(self.allocator, "{s}/.git/config", .{repo_path})
        else
            try std.fmt.allocPrint(self.allocator, "{s}/config", .{repo_path});
        defer self.allocator.free(config_path);

        const file = std.fs.openFileAbsolute(config_path, .{}) catch return;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 65536) catch return;
        defer self.allocator.free(content);

        const config = parsing.parseGitConfig(content, self.allocator) catch return;
        defer config.deinit();

        // Extract cgit-specific configuration from git config
        if (config.get("gitweb.desc")) |desc| {
            repo.desc = try self.allocator.dupe(u8, desc);
        }
        if (config.get("gitweb.owner")) |owner| {
            repo.owner = try self.allocator.dupe(u8, owner);
        }
        if (config.get("gitweb.homepage")) |homepage| {
            repo.homepage = try self.allocator.dupe(u8, homepage);
        }
        if (config.get("gitweb.defbranch")) |defbranch| {
            repo.defbranch = try self.allocator.dupe(u8, defbranch);
        }
        if (config.get("gitweb.section")) |section| {
            repo.section = try self.allocator.dupe(u8, section);
        }
        if (config.get("gitweb.clone-url")) |clone_url| {
            repo.clone_url = try self.allocator.dupe(u8, clone_url);
        }
        if (config.get("gitweb.hide")) |hide| {
            repo.hide = parsing.parseBool(hide);
        }
    }

    pub fn sortRepos(self: *RepoScanner, sort_key: []const u8, ascending: bool) void {
        const Context = struct {
            key: []const u8,
            ascending: bool,
        };

        const context = Context{
            .key = sort_key,
            .ascending = ascending,
        };

        std.sort.pdq(*gitweb.Repo, self.repos.items, context, struct {
            fn lessThan(ctx: Context, a: *gitweb.Repo, b: *gitweb.Repo) bool {
                const result = if (std.mem.eql(u8, ctx.key, "name"))
                    std.mem.order(u8, a.name, b.name)
                else if (std.mem.eql(u8, ctx.key, "age"))
                    std.math.order(a.last_modified, b.last_modified)
                else if (std.mem.eql(u8, ctx.key, "owner"))
                    std.mem.order(u8, a.owner orelse "", b.owner orelse "")
                else
                    std.mem.order(u8, a.url, b.url);

                return if (ctx.ascending)
                    result == .lt
                else
                    result == .gt;
            }
        }.lessThan);
    }

    pub fn filterRepos(self: *RepoScanner, filter_fn: *const fn (repo: *gitweb.Repo) bool) !std.ArrayList(*gitweb.Repo) {
        var filtered = std.ArrayList(*gitweb.Repo){
            .items = &.{},
            .capacity = 0,
        };

        for (self.repos.items) |repo| {
            if (filter_fn(repo)) {
                try filtered.append(self.allocator, repo);
            }
        }

        return filtered;
    }
};

fn matchPattern(path: []const u8, pattern: []const u8) bool {
    // Simple glob matching
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.startsWith(u8, pattern, "*/")) {
        return std.mem.endsWith(u8, path, pattern[1..]);
    }
    if (std.mem.endsWith(u8, pattern, "/*")) {
        return std.mem.startsWith(u8, path, pattern[0 .. pattern.len - 1]);
    }
    if (std.mem.indexOf(u8, pattern, "*")) |pos| {
        const prefix = pattern[0..pos];
        const suffix = pattern[pos + 1 ..];
        return std.mem.startsWith(u8, path, prefix) and std.mem.endsWith(u8, path, suffix);
    }
    return std.mem.indexOf(u8, path, pattern) != null;
}

test "matchPattern" {
    try std.testing.expect(matchPattern("/path/to/repo", "*"));
    try std.testing.expect(matchPattern("/path/to/repo", "*/repo"));
    try std.testing.expect(matchPattern("/path/to/repo", "/path/*"));
    try std.testing.expect(matchPattern("/path/to/repo", "*to*"));
    try std.testing.expect(!matchPattern("/path/to/repo", "*/other"));
}

const std = @import("std");
const gitweb = @import("gitweb.zig");
const parsing = @import("parsing.zig");

pub const ConfigParser = struct {
    allocator: std.mem.Allocator,
    callbacks: std.StringHashMap(*const fn (ctx: *gitweb.Context, key: []const u8, value: []const u8) anyerror!void),
    includes: std.ArrayList([]const u8),
    macros: std.StringHashMap([]const u8),
    current_section: ?[]const u8,
    current_repo: ?*gitweb.Repo,
    line_number: u32,
    file_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) ConfigParser {
        return .{
            .allocator = allocator,
            .callbacks = std.StringHashMap(*const fn (ctx: *gitweb.Context, key: []const u8, value: []const u8) anyerror!void).init(allocator),
            .includes = std.ArrayList([]const u8){
                .items = &.{},
                .capacity = 0,
            },
            .macros = std.StringHashMap([]const u8).init(allocator),
            .current_section = null,
            .current_repo = null,
            .line_number = 0,
            .file_path = "",
        };
    }

    pub fn deinit(self: *ConfigParser) void {
        self.callbacks.deinit();
        self.includes.deinit(self.allocator);
        self.macros.deinit();
    }

    pub fn registerCallback(self: *ConfigParser, key: []const u8, callback: *const fn (ctx: *gitweb.Context, key: []const u8, value: []const u8) anyerror!void) !void {
        try self.callbacks.put(key, callback);
    }

    pub fn parseFile(self: *ConfigParser, ctx: *gitweb.Context, path: []const u8) !void {
        self.file_path = path;
        self.line_number = 0;

        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(content);

        try self.parseContent(ctx, content);
    }

    pub fn parseContent(self: *ConfigParser, ctx: *gitweb.Context, content: []const u8) !void {
        var lines = std.mem.split(u8, content, "\n");

        while (lines.next()) |line| {
            self.line_number += 1;
            try self.parseLine(ctx, line);
        }
    }

    fn parseLine(self: *ConfigParser, ctx: *gitweb.Context, line: []const u8) !void {
        // Remove comments
        const comment_pos = std.mem.indexOf(u8, line, "#");
        const effective_line = if (comment_pos) |pos| line[0..pos] else line;

        // Trim whitespace
        const trimmed = std.mem.trim(u8, effective_line, " \t\r");
        if (trimmed.len == 0) return;

        // Check for directives
        if (std.mem.startsWith(u8, trimmed, "@")) {
            try self.handleDirective(ctx, trimmed[1..]);
            return;
        }

        // Check for section headers
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            self.current_section = try self.allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);

            // Check if this is a repo section
            if (std.mem.eql(u8, self.current_section.?, "repo") or
                std.mem.startsWith(u8, self.current_section.?, "repo:"))
            {
                // Start new repository
                self.current_repo = try gitweb.Repo.init(ctx.allocator);
                // TODO: Add repo to context's repo list
            }
            return;
        }

        // Parse key=value pairs
        const eq_pos = std.mem.indexOf(u8, trimmed, "=");
        if (eq_pos) |pos| {
            const key = std.mem.trim(u8, trimmed[0..pos], " \t");
            var value = std.mem.trim(u8, trimmed[pos + 1 ..], " \t");

            // Remove quotes if present
            if (value.len >= 2 and
                ((value[0] == '"' and value[value.len - 1] == '"') or
                    (value[0] == '\'' and value[value.len - 1] == '\'')))
            {
                value = value[1 .. value.len - 1];
            }

            // Expand macros
            value = try self.expandMacros(value);

            // Handle the key-value pair
            try self.handleKeyValue(ctx, key, value);
        }
    }

    fn handleDirective(self: *ConfigParser, ctx: *gitweb.Context, directive: []const u8) !void {
        var parts = std.mem.tokenizeAny(u8, directive, " \t");
        const cmd = parts.next() orelse return;

        if (std.mem.eql(u8, cmd, "include")) {
            const path = parts.next() orelse return;
            const expanded_path = try self.expandMacros(path);
            try self.includes.append(self.allocator, expanded_path);

            // Parse included file
            self.parseFile(ctx, expanded_path) catch |err| {
                std.log.warn("Failed to include {s}: {}", .{ expanded_path, err });
            };
        } else if (std.mem.eql(u8, cmd, "define")) {
            const name = parts.next() orelse return;
            const value = parts.rest();
            try self.macros.put(try self.allocator.dupe(u8, name), try self.allocator.dupe(u8, value));
        } else if (std.mem.eql(u8, cmd, "ifdef")) {
            const name = parts.next() orelse return;
            // TODO: Implement conditional parsing
            _ = name;
        } else if (std.mem.eql(u8, cmd, "ifndef")) {
            const name = parts.next() orelse return;
            // TODO: Implement conditional parsing
            _ = name;
        } else if (std.mem.eql(u8, cmd, "endif")) {
            // TODO: End conditional parsing
        }
    }

    fn handleKeyValue(self: *ConfigParser, ctx: *gitweb.Context, key: []const u8, value: []const u8) !void {
        // Check for registered callbacks
        if (self.callbacks.get(key)) |callback| {
            try callback(ctx, key, value);
            return;
        }

        // If we're in a repo section, handle repo-specific config
        if (self.current_repo) |repo| {
            try setRepoConfig(repo, key, value);
        } else {
            // Global configuration
            try setGlobalConfig(ctx, key, value);
        }
    }

    fn expandMacros(self: *ConfigParser, value: []const u8) ![]const u8 {
        var result = std.ArrayList(u8){
            .items = &.{},
            .capacity = 0,
        };
        defer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < value.len) {
            if (value[i] == '$' and i + 1 < value.len and value[i + 1] == '{') {
                // Find the closing brace
                const start = i + 2;
                var end = start;
                while (end < value.len and value[end] != '}') {
                    end += 1;
                }

                if (end < value.len) {
                    const macro_name = value[start..end];

                    // Try to find macro definition
                    if (self.macros.get(macro_name)) |macro_value| {
                        try result.appendSlice(self.allocator, macro_value);
                    } else if (std.process.getEnvVarOwned(self.allocator, macro_name)) |env_value| {
                        defer self.allocator.free(env_value);
                        try result.appendSlice(self.allocator, env_value);
                    } else |_| {
                        // Keep the original text if macro not found
                        try result.appendSlice(self.allocator, value[i .. end + 1]);
                    }

                    i = end + 1;
                    continue;
                }
            }

            try result.append(self.allocator, value[i]);
            i += 1;
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn setGlobalConfig(ctx: *gitweb.Context, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "cache-root")) {
            ctx.cfg.cache_root = try ctx.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "cache-size")) {
            ctx.cfg.cache_size = parsing.parseSize(value) orelse 0;
        } else if (std.mem.eql(u8, key, "cache-dynamic-ttl")) {
            ctx.cfg.cache_dynamic_ttl = std.fmt.parseInt(i32, value, 10) catch -1;
        } else if (std.mem.eql(u8, key, "cache-repo-ttl")) {
            ctx.cfg.cache_repo_ttl = std.fmt.parseInt(i32, value, 10) catch -1;
        } else if (std.mem.eql(u8, key, "cache-root-ttl")) {
            ctx.cfg.cache_root_ttl = std.fmt.parseInt(i32, value, 10) catch -1;
        } else if (std.mem.eql(u8, key, "css")) {
            ctx.cfg.css = try ctx.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "logo")) {
            ctx.cfg.logo = try ctx.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "logo-link")) {
            ctx.cfg.logo_link = try ctx.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "favicon")) {
            ctx.cfg.favicon = try ctx.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "robots")) {
            ctx.cfg.robots = try ctx.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "root-title")) {
            ctx.cfg.root_title = try ctx.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "root-desc")) {
            ctx.cfg.root_desc = try ctx.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "scan-path")) {
            ctx.cfg.scanpath = try ctx.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "virtual-root")) {
            ctx.cfg.virtual_root = try ctx.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "enable-index-links")) {
            ctx.cfg.enable_index_links = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "enable-index-owner")) {
            ctx.cfg.enable_index_owner = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "enable-log-filecount")) {
            ctx.cfg.enable_log_filecount = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "enable-log-linecount")) {
            ctx.cfg.enable_log_linecount = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "enable-tree-linenumbers")) {
            ctx.cfg.enable_tree_linenumbers = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "enable-blame")) {
            ctx.cfg.enable_blame = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "max-repo-count")) {
            ctx.cfg.max_repo_count = std.fmt.parseInt(u32, value, 10) catch 50;
        } else if (std.mem.eql(u8, key, "max-commit-count")) {
            ctx.cfg.max_commit_count = std.fmt.parseInt(u32, value, 10) catch 50;
        } else if (std.mem.eql(u8, key, "max-blob-size")) {
            ctx.cfg.max_blob_size = std.fmt.parseInt(u32, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "nocache")) {
            ctx.cfg.nocache = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "noheader")) {
            ctx.cfg.noheader = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "embedded")) {
            ctx.cfg.embedded = parsing.parseBool(value);
        } else if (std.mem.startsWith(u8, key, "mimetype.")) {
            const ext = key[9..];
            try ctx.cfg.mimetypes.put(try ctx.allocator.dupe(u8, ext), try ctx.allocator.dupe(u8, value));
        }
    }

    fn setRepoConfig(repo: *gitweb.Repo, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "url")) {
            repo.url = try repo.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "name")) {
            repo.name = try repo.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "path")) {
            repo.path = try repo.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "desc")) {
            repo.desc = try repo.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "owner")) {
            repo.owner = try repo.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "defbranch")) {
            repo.defbranch = try repo.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "homepage")) {
            repo.homepage = try repo.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "clone-url")) {
            repo.clone_url = try repo.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "logo")) {
            repo.logo = try repo.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "logo-link")) {
            repo.logo_link = try repo.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "enable-blame")) {
            repo.enable_blame = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "enable-commit-graph")) {
            repo.enable_commit_graph = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "enable-log-filecount")) {
            repo.enable_log_filecount = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "enable-log-linecount")) {
            repo.enable_log_linecount = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "hide")) {
            repo.hide = parsing.parseBool(value);
        } else if (std.mem.eql(u8, key, "ignore")) {
            repo.ignore = parsing.parseBool(value);
        }
    }
};

// Tests
const testing = std.testing;

test ConfigParser {
    const allocator = testing.allocator;
    var parser = ConfigParser.init(allocator);
    defer parser.deinit();

    // Test macro expansion
    try parser.macros.put("HOME", "/home/user");
    try parser.macros.put("REPOS", "${HOME}/repos");

    const expanded = try parser.expandMacros("${REPOS}/test.git");
    defer allocator.free(expanded);
    try testing.expectEqualStrings("/home/user/repos/test.git", expanded);
}

test "parseLine sections" {
    const allocator = testing.allocator;
    var parser = ConfigParser.init(allocator);
    defer parser.deinit();

    var ctx = try gitweb.Context.init(allocator);
    defer ctx.deinit();

    // Test section parsing
    try parser.parseLine(&ctx, "[general]");
    try testing.expect(parser.current_section != null);
    try testing.expectEqualStrings("general", parser.current_section.?);

    // Test comment handling
    try parser.parseLine(&ctx, "# This is a comment");
    try parser.parseLine(&ctx, "key = value # inline comment");
}

test "keyValue parsing" {
    const allocator = testing.allocator;
    var parser = ConfigParser.init(allocator);
    defer parser.deinit();

    var ctx = try gitweb.Context.init(allocator);
    defer ctx.deinit();

    // Test callback registration
    const testCallback = struct {
        fn callback(c: *gitweb.Context, key: []const u8, value: []const u8) !void {
            _ = c;
            if (std.mem.eql(u8, key, "test-key")) {
                try testing.expectEqualStrings("test-value", value);
            }
        }
    }.callback;

    try parser.registerCallback("test-key", testCallback);
    try parser.parseLine(&ctx, "test-key = test-value");
}

test parseContent {
    const allocator = testing.allocator;
    var parser = ConfigParser.init(allocator);
    defer parser.deinit();

    var ctx = try gitweb.Context.init(allocator);
    defer ctx.deinit();

    const config =
        \\# Test config
        \\[general]
        \\cache-size = 1M
        \\enable-blame = true
        \\
        \\[repo]
        \\url = test.git
        \\name = Test Repository
    ;

    try parser.parseContent(&ctx, config);

    // Verify cache size was parsed (1M = 1048576)
    try testing.expectEqual(@as(usize, 1048576), ctx.cfg.cache_size);
    try testing.expect(ctx.cfg.enable_blame);
}

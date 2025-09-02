const std = @import("std");
const gitweb = @import("gitweb.zig");

pub fn loadConfig(ctx: *gitweb.Context) !void {
    // Check GITWEB_CONFIG environment variable, then binary directory, then cwd, then default location
    const config_file = std.process.getEnvVarOwned(ctx.allocator, "GITWEB_CONFIG") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            // Try to get the binary's directory
            const exe_path = try std.fs.selfExePathAlloc(ctx.allocator);
            defer ctx.allocator.free(exe_path);

            const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
            const binary_conf = try std.fs.path.join(ctx.allocator, &.{ exe_dir, "gitweb.conf" });
            defer ctx.allocator.free(binary_conf);

            // Debug output to stderr (commented out for production)
            // std.debug.print("Checking for config at: {s}\n", .{binary_conf});

            // Try binary directory first
            if (std.fs.openFileAbsolute(binary_conf, .{})) |f| {
                f.close();
                // std.debug.print("Found config in binary directory: {s}\n", .{binary_conf});
                break :blk try ctx.allocator.dupe(u8, binary_conf);
            } else |_| {
                // Try current working directory
                // std.debug.print("Checking for config at: gitweb.conf (cwd)\n", .{});
                if (std.fs.cwd().access("gitweb.conf", .{})) |_| {
                    // std.debug.print("Found config in current directory\n", .{});
                    break :blk try ctx.allocator.dupe(u8, "gitweb.conf");
                } else |_| {
                    // Fall back to default location
                    // std.debug.print("Checking for config at: /etc/gitweb.conf\n", .{});
                    break :blk try ctx.allocator.dupe(u8, "/etc/gitweb.conf");
                }
            }
        }
        return err;
    };
    defer ctx.allocator.free(config_file);

    // std.debug.print("Attempting to load config from: {s}\n", .{config_file});

    // Try to open and parse config file
    const file = if (std.fs.path.isAbsolute(config_file))
        std.fs.openFileAbsolute(config_file, .{})
    else
        std.fs.cwd().openFile(config_file, .{});

    const opened_file = file catch |err| {
        if (err == error.FileNotFound) {
            // Config file is optional, use defaults
            // std.debug.print("Config file not found at {s}, using defaults\n", .{config_file});
            return;
        }
        // std.debug.print("Error opening config file: {}\n", .{err});
        return err;
    };
    defer opened_file.close();

    // std.debug.print("Successfully opened config file: {s}\n", .{config_file});

    const content = try opened_file.readToEndAlloc(ctx.allocator, std.math.maxInt(usize));
    defer ctx.allocator.free(content);

    try parseConfig(ctx, content);
}

fn parseConfig(ctx: *gitweb.Context, content: []const u8) !void {
    var lines = std.mem.tokenizeAny(u8, content, "\n");
    var current_repo: ?*gitweb.Repo = null;

    while (lines.next()) |line| {
        // Skip comments and empty lines
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }

        // Check for repo section
        if (std.mem.startsWith(u8, trimmed, "repo.")) {
            const repo_section = trimmed[5..];
            if (std.mem.eql(u8, repo_section, "url")) {
                // Start new repo
                current_repo = try gitweb.Repo.init(ctx.allocator);
                // TODO: Add repo to context's repo list
            }
            continue;
        }

        // Parse key=value
        const eq_pos = std.mem.indexOf(u8, trimmed, "=");
        if (eq_pos) |pos| {
            const key = std.mem.trim(u8, trimmed[0..pos], " \t");
            const value = std.mem.trim(u8, trimmed[pos + 1 ..], " \t\"");

            if (current_repo) |repo| {
                try setRepoConfig(repo, key, value);
            } else {
                try setGlobalConfig(ctx, key, value);
            }
        }
    }
}

fn setGlobalConfig(ctx: *gitweb.Context, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "scan-path")) {
        // Free old value if it exists
        if (ctx.cfg.scanpath) |old| {
            ctx.allocator.free(old);
        }
        ctx.cfg.scanpath = try ctx.allocator.dupe(u8, value);
        // std.debug.print("Set scan-path to: {s}\n", .{value});
    } else if (std.mem.eql(u8, key, "project-list")) {
        // Free old value if it exists
        if (ctx.cfg.project_list) |old| {
            ctx.allocator.free(old);
        }
        ctx.cfg.project_list = try ctx.allocator.dupe(u8, value);
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
    } else if (std.mem.eql(u8, key, "homepage")) {
        repo.homepage = try repo.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "defbranch")) {
        repo.defbranch = try repo.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "module-link")) {
        repo.module_link = try repo.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "section")) {
        repo.section = try repo.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "clone-url")) {
        repo.clone_url = try repo.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "logo")) {
        repo.logo = try repo.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "logo-link")) {
        repo.logo_link = try repo.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "snapshots")) {
        repo.snapshots = try parseSnapshotFormats(value);
    } else if (std.mem.eql(u8, key, "enable-blame")) {
        repo.enable_blame = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "enable-commit-graph")) {
        repo.enable_commit_graph = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "enable-log-filecount")) {
        repo.enable_log_filecount = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "enable-log-linecount")) {
        repo.enable_log_linecount = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "enable-remote-branches")) {
        repo.enable_remote_branches = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "enable-subject-links")) {
        repo.enable_subject_links = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "enable-html-serving")) {
        repo.enable_html_serving = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "branch-sort")) {
        if (std.mem.eql(u8, value, "age")) {
            repo.branch_sort = .age;
        } else {
            repo.branch_sort = .name;
        }
    } else if (std.mem.eql(u8, key, "commit-sort")) {
        if (std.mem.eql(u8, value, "topo")) {
            repo.commit_sort = .topo;
        } else {
            repo.commit_sort = .date;
        }
    } else if (std.mem.eql(u8, key, "max-stats")) {
        repo.max_stats = parseStatsPeriod(value);
    } else if (std.mem.eql(u8, key, "hide")) {
        repo.hide = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "ignore")) {
        repo.ignore = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "readme")) {
        try repo.readme.append(repo.allocator, try repo.allocator.dupe(u8, value));
    } else if (std.mem.startsWith(u8, key, "module-link.")) {
        const module = key[12..];
        try repo.submodules.put(try repo.allocator.dupe(u8, module), try repo.allocator.dupe(u8, value));
    }
}

fn parseStatsPeriod(value: []const u8) gitweb.Period {
    if (std.mem.eql(u8, value, "week")) {
        return .week;
    } else if (std.mem.eql(u8, value, "month")) {
        return .month;
    } else if (std.mem.eql(u8, value, "quarter")) {
        return .quarter;
    } else {
        return .year;
    }
}

fn parseSnapshotFormats(value: []const u8) !u32 {
    var mask: u32 = 0;
    var iter = std.mem.tokenizeAny(u8, value, " ");
    while (iter.next()) |format| {
        if (std.mem.eql(u8, format, "tar")) {
            mask |= 1 << 0;
        } else if (std.mem.eql(u8, format, "tar.gz")) {
            mask |= 1 << 1;
        } else if (std.mem.eql(u8, format, "tar.bz2")) {
            mask |= 1 << 2;
        } else if (std.mem.eql(u8, format, "tar.xz")) {
            mask |= 1 << 3;
        } else if (std.mem.eql(u8, format, "tar.zst")) {
            mask |= 1 << 4;
        } else if (std.mem.eql(u8, format, "zip")) {
            mask |= 1 << 5;
        }
    }
    return mask;
}

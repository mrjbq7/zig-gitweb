const std = @import("std");
const gitweb = @import("gitweb.zig");

pub fn loadConfig(ctx: *gitweb.Context) !void {
    // First check environment variable
    const config_file = std.process.getEnvVarOwned(ctx.allocator, "CGIT_CONFIG") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            // Fall back to default location
            break :blk try ctx.allocator.dupe(u8, "/etc/cgitrc");
        }
        return err;
    };
    defer ctx.allocator.free(config_file);
    
    // Try to open and parse config file
    const file = std.fs.openFileAbsolute(config_file, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Config file is optional, use defaults
            return;
        }
        return err;
    };
    defer file.close();
    
    const content = try file.readToEndAlloc(ctx.allocator, std.math.maxInt(usize));
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
            const value = std.mem.trim(u8, trimmed[pos + 1..], " \t\"");
            
            if (current_repo) |repo| {
                try setRepoConfig(repo, key, value);
            } else {
                try setGlobalConfig(ctx, key, value);
            }
        }
    }
}

fn setGlobalConfig(ctx: *gitweb.Context, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "cache-root")) {
        ctx.cfg.cache_root = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "cache-size")) {
        ctx.cfg.cache_size = try std.fmt.parseInt(usize, value, 10);
    } else if (std.mem.eql(u8, key, "cache-dynamic-ttl")) {
        ctx.cfg.cache_dynamic_ttl = try std.fmt.parseInt(i32, value, 10);
    } else if (std.mem.eql(u8, key, "cache-repo-ttl")) {
        ctx.cfg.cache_repo_ttl = try std.fmt.parseInt(i32, value, 10);
    } else if (std.mem.eql(u8, key, "cache-root-ttl")) {
        ctx.cfg.cache_root_ttl = try std.fmt.parseInt(i32, value, 10);
    } else if (std.mem.eql(u8, key, "clone-prefix")) {
        ctx.cfg.clone_prefix = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "clone-url")) {
        ctx.cfg.clone_url = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "css")) {
        ctx.cfg.css = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "embedded")) {
        ctx.cfg.embedded = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "enable-index-links")) {
        ctx.cfg.enable_index_links = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "enable-index-owner")) {
        ctx.cfg.enable_index_owner = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "enable-commit-graph")) {
        ctx.cfg.enable_commit_graph = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "enable-log-filecount")) {
        ctx.cfg.enable_log_filecount = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "enable-log-linecount")) {
        ctx.cfg.enable_log_linecount = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "favicon")) {
        ctx.cfg.favicon = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "footer")) {
        ctx.cfg.footer = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "head-include")) {
        ctx.cfg.head_include = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "header")) {
        ctx.cfg.header = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "logo")) {
        ctx.cfg.logo = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "logo-link")) {
        ctx.cfg.logo_link = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "max-atom-items")) {
        ctx.cfg.max_atom_items = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, key, "max-commit-count")) {
        ctx.cfg.max_commit_count = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, key, "max-message-length")) {
        ctx.cfg.max_msg_len = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, key, "max-repo-count")) {
        ctx.cfg.max_repo_count = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, key, "max-repodesc-length")) {
        ctx.cfg.max_repodesc_len = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, key, "max-blob-size")) {
        ctx.cfg.max_blob_size = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, key, "max-stats")) {
        ctx.cfg.max_stats = parseStatsPeriod(value);
    } else if (std.mem.eql(u8, key, "mimetype-file")) {
        ctx.cfg.mimetype_file = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "module-link")) {
        ctx.cfg.module_link = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "nocache")) {
        ctx.cfg.nocache = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "noheader")) {
        ctx.cfg.noheader = std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "project-list")) {
        ctx.cfg.project_list = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "readme")) {
        ctx.cfg.readme = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "robots")) {
        ctx.cfg.robots = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "root-title")) {
        ctx.cfg.root_title = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "root-desc")) {
        ctx.cfg.root_desc = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "root-readme")) {
        ctx.cfg.root_readme = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "scan-path")) {
        ctx.cfg.scanpath = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "section")) {
        ctx.cfg.section = try ctx.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "snapshots")) {
        ctx.cfg.snapshots = try parseSnapshotFormats(value);
    } else if (std.mem.eql(u8, key, "summary-branches")) {
        ctx.cfg.summary_branches = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, key, "summary-log")) {
        ctx.cfg.summary_log = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, key, "summary-tags")) {
        ctx.cfg.summary_tags = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, key, "virtual-root")) {
        ctx.cfg.virtual_root = try ctx.allocator.dupe(u8, value);
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
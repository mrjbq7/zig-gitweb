const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");

pub fn repolist(ctx: *gitweb.Context, writer: anytype) !void {
    try writer.writeAll("<div class='repolist'>\n");

    // Structure to hold repository information
    const RepoInfo = struct {
        name: []const u8,
        description: []const u8,
        owner: []const u8,
        idle: []const u8,
        last_commit_time: ?i64,
    };

    // Scan for repositories if scan-path is configured
    if (ctx.cfg.scanpath) |scan_path| {
        // std.debug.print("repolist: Scanning path: {s}\n", .{scan_path});

        var dir = std.fs.openDirAbsolute(scan_path, .{ .iterate = true }) catch {
            try writer.writeAll("<div class='repolist-empty'>Failed to open repository directory</div>\n");
            try writer.writeAll("</div>\n");
            return;
        };
        defer dir.close();

        // Collect repositories
        var repos: std.ArrayList(RepoInfo) = .empty;
        defer {
            for (repos.items) |repo| {
                ctx.allocator.free(repo.name);
                if (repo.description.len > 0) ctx.allocator.free(repo.description);
            }
            repos.deinit(ctx.allocator);
        }

        var iter = dir.iterate();

        while (try iter.next()) |entry| {
            // Check if this is a git repository (either bare or .git directory)
            const is_git_repo = blk: {
                if (std.mem.endsWith(u8, entry.name, ".git")) {
                    break :blk true;
                }
                // Check if it's a bare repository by looking for HEAD file
                const repo_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ scan_path, entry.name });
                defer ctx.allocator.free(repo_path);

                const head_path = try std.fmt.allocPrint(ctx.allocator, "{s}/HEAD", .{repo_path});
                defer ctx.allocator.free(head_path);

                std.fs.accessAbsolute(head_path, .{}) catch {
                    break :blk false;
                };
                break :blk true;
            };

            if (is_git_repo) {
                // Extract repository name (remove .git suffix if present)
                var repo_name = entry.name;
                if (std.mem.endsWith(u8, repo_name, ".git")) {
                    repo_name = repo_name[0 .. repo_name.len - 4];
                }

                // Try to get repository description
                const repo_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ scan_path, entry.name });
                defer ctx.allocator.free(repo_path);

                const desc_path = try std.fmt.allocPrint(ctx.allocator, "{s}/description", .{repo_path});
                defer ctx.allocator.free(desc_path);

                const description = blk: {
                    const file = std.fs.openFileAbsolute(desc_path, .{}) catch {
                        break :blk "";
                    };
                    defer file.close();

                    const content = file.readToEndAlloc(ctx.allocator, 1024) catch {
                        break :blk "";
                    };

                    // Trim whitespace and check if it's the default description
                    const trimmed = std.mem.trim(u8, content, " \t\r\n");
                    if (std.mem.startsWith(u8, trimmed, "Unnamed repository")) {
                        ctx.allocator.free(content);
                        break :blk "";
                    }
                    // Return a duplicate of the trimmed string so it persists
                    const desc_copy = ctx.allocator.dupe(u8, trimmed) catch {
                        ctx.allocator.free(content);
                        break :blk "";
                    };
                    ctx.allocator.free(content);
                    break :blk desc_copy;
                };

                // Try to get last commit time
                const last_commit_time = blk: {
                    var git_repo = git.Repository.open(repo_path) catch {
                        break :blk null;
                    };
                    defer git_repo.close();

                    var walk = git_repo.revwalk() catch {
                        break :blk null;
                    };
                    defer walk.free();

                    walk.pushHead() catch {
                        break :blk null;
                    };

                    if (walk.next()) |oid| {
                        var commit = git_repo.lookupCommit(&oid) catch {
                            break :blk null;
                        };
                        defer commit.free();
                        break :blk commit.time();
                    }
                    break :blk null;
                };

                try repos.append(ctx.allocator, RepoInfo{
                    .name = try ctx.allocator.dupe(u8, repo_name),
                    .description = description,
                    .owner = "",
                    .idle = "",
                    .last_commit_time = last_commit_time,
                });
            }
        }

        // Sort repositories by name
        std.sort.pdq(RepoInfo, repos.items, {}, struct {
            fn lessThan(_: void, a: RepoInfo, b: RepoInfo) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        // Display sorted repositories
        for (repos.items) |repo| {
            try writer.writeAll("<div class='repo-item'>\n");

            // Repository name and description
            try writer.writeAll("<div class='repo-main'>\n");

            // Name
            try writer.writeAll("<div class='repo-name'>\n");
            try writer.print("<a href='?r={s}'>{s}</a>", .{ repo.name, repo.name });
            try writer.writeAll("</div>\n");

            // Description
            if (repo.description.len > 0) {
                try writer.writeAll("<div class='repo-description'>\n");
                try html.htmlEscape(writer, repo.description);
                try writer.writeAll("</div>\n");
            }

            try writer.writeAll("</div>\n"); // repo-main

            // Metadata
            try writer.writeAll("<div class='repo-meta'>\n");

            // Last activity
            if (repo.last_commit_time) |commit_time| {
                try writer.writeAll("<span class='repo-activity'>\n");
                try shared.formatAge(writer, commit_time);
                try writer.writeAll("</span>\n");
            }

            // Actions
            try writer.writeAll("<span class='repo-actions'>\n");
            try writer.print("<a href='?r={s}&cmd=summary'>summary</a>", .{repo.name});
            try writer.writeAll(" | ");
            try writer.print("<a href='?r={s}&cmd=log'>log</a>", .{repo.name});
            try writer.writeAll(" | ");
            try writer.print("<a href='?r={s}&cmd=tree'>tree</a>", .{repo.name});
            try writer.writeAll("</span>\n");

            try writer.writeAll("</div>\n"); // repo-meta
            try writer.writeAll("</div>\n"); // repo-item
        }

        if (repos.items.len == 0) {
            try writer.writeAll("<div class='repolist-empty'>No repositories found</div>\n");
        }
    } else {
        try writer.writeAll("<div class='repolist-empty'>No scan path configured</div>\n");
    }
    try writer.writeAll("</div>\n");
}

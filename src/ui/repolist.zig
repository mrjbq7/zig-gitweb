const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");

pub fn repolist(ctx: *gitweb.Context, writer: anytype) !void {
    try writer.writeAll("<div class='repolist'>\n");
    try writer.print("<h2>{s}</h2>\n", .{ctx.cfg.root_title});
    try writer.print("<p>{s}</p>\n", .{ctx.cfg.root_desc});

    // Table headers
    try writer.writeAll("<table class='list nowrap'>\n");
    try writer.writeAll("<tr class='nohover'>");
    try writer.writeAll("<th class='left'>Name</th>");
    try writer.writeAll("<th class='left'>Description</th>");
    try writer.writeAll("<th class='left'>Owner</th>");
    try writer.writeAll("<th class='left'>Idle</th>");
    try writer.writeAll("</tr>\n");

    // Scan for repositories if scan-path is configured
    if (ctx.cfg.scanpath) |scan_path| {
        // std.debug.print("repolist: Scanning path: {s}\n", .{scan_path});

        var dir = std.fs.openDirAbsolute(scan_path, .{ .iterate = true }) catch {
            try writer.writeAll("<tr><td colspan='4'>Failed to open repository directory</td></tr>\n");
            try writer.writeAll("</table>\n");
            try writer.writeAll("</div>\n");
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        var repo_count: usize = 0;

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
                repo_count += 1;

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
                        break :blk "Unnamed repository; edit this file 'description' to name the repository.";
                    };
                    defer file.close();

                    const content = file.readToEndAlloc(ctx.allocator, 1024) catch {
                        break :blk "Unnamed repository; edit this file 'description' to name the repository.";
                    };
                    defer ctx.allocator.free(content);

                    // Trim whitespace and check if it's the default description
                    const trimmed = std.mem.trim(u8, content, " \t\r\n");
                    if (std.mem.startsWith(u8, trimmed, "Unnamed repository")) {
                        break :blk "";
                    }
                    break :blk trimmed;
                };

                // Write table row
                try writer.writeAll("<tr>");

                // Name column with link
                try writer.writeAll("<td>");
                try writer.print("<a href='?r={s}'>{s}</a>", .{ repo_name, repo_name });
                try writer.writeAll("</td>");

                // Description column
                try writer.writeAll("<td>");
                if (description.len > 0) {
                    try html.htmlEscape(writer, description);
                }
                try writer.writeAll("</td>");

                // Owner column (TODO: get from config or git config)
                try writer.writeAll("<td></td>");

                // Idle column (TODO: get last commit time)
                try writer.writeAll("<td></td>");

                try writer.writeAll("</tr>\n");
            }
        }

        if (repo_count == 0) {
            try writer.writeAll("<tr><td colspan='4'>No repositories found</td></tr>\n");
        }
    } else {
        try writer.writeAll("<tr><td colspan='4'>No scan path configured</td></tr>\n");
    }

    try writer.writeAll("</table>\n");
    try writer.writeAll("</div>\n");
}

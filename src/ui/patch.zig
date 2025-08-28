const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");

pub fn patch(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    const commit_id = ctx.query.get("id") orelse return error.NoCommitId;

    // Set content type for patch
    ctx.page.mimetype = "text/plain";
    ctx.page.filename = try std.fmt.allocPrint(ctx.allocator, "{s}.patch", .{commit_id[0..@min(7, commit_id.len)]});

    // TODO: Generate actual patch
    try writer.print("From {s}\n", .{commit_id});
    try writer.writeAll("From: Author Name <author@example.com>\n");
    try writer.writeAll("Date: Date will be shown here\n");
    try writer.writeAll("Subject: [PATCH] Commit subject\n");
    try writer.writeAll("\n");
    try writer.writeAll("Patch content will be shown here\n");
    _ = repo;
}

const std = @import("std");
const gitweb = @import("../gitweb.zig");

pub fn atom(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    // Set content type for Atom feed
    ctx.page.mimetype = "application/atom+xml";
    ctx.page.charset = "UTF-8";

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try writer.writeAll("<feed xmlns=\"http://www.w3.org/2005/Atom\">\n");

    try writer.print("  <title>{s} - Commits</title>\n", .{repo.name});
    try writer.print("  <id>urn:uuid:{s}</id>\n", .{repo.url});
    try writer.writeAll("  <updated>2024-01-01T00:00:00Z</updated>\n"); // TODO: Use actual date

    if (repo.homepage) |homepage| {
        try writer.print("  <link href=\"{s}\" rel=\"alternate\" type=\"text/html\"/>\n", .{homepage});
    }

    // TODO: Add actual commit entries

    try writer.writeAll("</feed>\n");
}

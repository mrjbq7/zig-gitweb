const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");

pub fn tag(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    const tag_name = ctx.query.get("id") orelse return error.NoTagId;

    try writer.writeAll("<div class='tag'>\n");
    try writer.print("<h2>Tag: {s}</h2>\n", .{tag_name});

    // TODO: Load tag details from git
    try writer.writeAll("<table class='tag-info'>\n");
    try writer.writeAll("<tr><th>Tagged by</th><td>Tagger name</td></tr>\n");
    try writer.writeAll("<tr><th>Tagged on</th><td>Date will be shown here</td></tr>\n");
    try writer.writeAll("<tr><th>Tagged commit</th><td>Commit link will be shown here</td></tr>\n");
    try writer.writeAll("</table>\n");

    try writer.writeAll("<div class='tag-message'>\n");
    try writer.writeAll("<pre>Tag message will be shown here</pre>\n");
    try writer.writeAll("</div>\n");

    try writer.writeAll("</div>\n");
    _ = repo;
}

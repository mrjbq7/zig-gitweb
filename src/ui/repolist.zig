const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");

pub fn repolist(ctx: *gitweb.Context, writer: anytype) !void {
    try writer.writeAll("<div class='repolist'>\n");
    try writer.print("<h2>{s}</h2>\n", .{ctx.cfg.root_title});
    try writer.print("<p>{s}</p>\n", .{ctx.cfg.root_desc});
    
    // Table headers
    const headers = [_][]const u8{ "Name", "Description", "Owner", "Idle" };
    try html.writeTableHeader(writer, &headers);
    
    // TODO: Iterate through repositories
    // For now, just show a placeholder
    try html.writeTableRow(writer, null);
    try html.writeTableCell(writer, null, "example-repo");
    try html.writeTableCell(writer, null, "An example repository");
    try html.writeTableCell(writer, null, "admin");
    try html.writeTableCell(writer, null, "2 hours ago");
    try writer.writeAll("</tr>\n");
    
    try html.writeTableFooter(writer);
    try writer.writeAll("</div>\n");
}
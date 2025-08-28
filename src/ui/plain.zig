const std = @import("std");
const gitweb = @import("../gitweb.zig");

pub fn plain(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    const path = ctx.query.get("path") orelse return error.NoPath;
    
    // Determine MIME type based on file extension
    const ext = std.fs.path.extension(path);
    if (ctx.cfg.mimetypes.get(ext)) |mimetype| {
        ctx.page.mimetype = mimetype;
    } else if (std.mem.eql(u8, ext, ".txt")) {
        ctx.page.mimetype = "text/plain";
    } else if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) {
        ctx.page.mimetype = "text/html";
    } else if (std.mem.eql(u8, ext, ".css")) {
        ctx.page.mimetype = "text/css";
    } else if (std.mem.eql(u8, ext, ".js")) {
        ctx.page.mimetype = "application/javascript";
    } else if (std.mem.eql(u8, ext, ".json")) {
        ctx.page.mimetype = "application/json";
    } else if (std.mem.eql(u8, ext, ".xml")) {
        ctx.page.mimetype = "application/xml";
    } else if (std.mem.eql(u8, ext, ".png")) {
        ctx.page.mimetype = "image/png";
    } else if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) {
        ctx.page.mimetype = "image/jpeg";
    } else if (std.mem.eql(u8, ext, ".gif")) {
        ctx.page.mimetype = "image/gif";
    } else {
        ctx.page.mimetype = "application/octet-stream";
    }
    
    // TODO: Serve actual file content from git
    try writer.writeAll("File content will be served here\n");
    _ = repo;
}
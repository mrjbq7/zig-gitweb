const std = @import("std");
const gitweb = @import("gitweb.zig");
const cache = @import("cache.zig");
const cmd = @import("cmd.zig");
const config = @import("config.zig");
const html = @import("html.zig");
const ui = @import("ui/shared.zig");
const git = @import("git.zig");

pub const version = "v0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize libgit2
    _ = git.c.git_libgit2_init();
    defer _ = git.c.git_libgit2_shutdown();

    // Set up environment similar to cgit's constructor
    try setupEnvironment();

    // Initialize context
    var ctx = try gitweb.Context.init(allocator);
    defer ctx.deinit();

    // Parse configuration
    try config.loadConfig(&ctx);

    // Process CGI request
    try processCgiRequest(&ctx);
}

fn setupEnvironment() !void {
    // Similar to cgit's constructor_environment
    // In Zig 0.15, we use C's setenv since std doesn't have it
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    _ = c.setenv("GIT_CONFIG_NOSYSTEM", "1", 1);
    _ = c.setenv("GIT_ATTR_NOSYSTEM", "1", 1);
    // Note: In Zig we don't unset HOME/XDG_CONFIG_HOME for safety
}

fn processCgiRequest(ctx: *gitweb.Context) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Parse CGI environment variables
    const query_string = std.process.getEnvVarOwned(ctx.allocator, "QUERY_STRING") catch blk: {
        break :blk try ctx.allocator.dupe(u8, "");
    };
    defer ctx.allocator.free(query_string);

    const path_info = std.process.getEnvVarOwned(ctx.allocator, "PATH_INFO") catch blk: {
        break :blk try ctx.allocator.dupe(u8, "");
    };
    defer ctx.allocator.free(path_info);

    const request_method = std.process.getEnvVarOwned(ctx.allocator, "REQUEST_METHOD") catch blk: {
        break :blk try ctx.allocator.dupe(u8, "GET");
    };
    defer ctx.allocator.free(request_method);

    // Parse request
    try ctx.parseRequest(query_string, path_info, request_method);

    // Check cache if enabled
    if (ctx.cfg.cache_enabled) {
        if (try cache.tryServeFromCache(ctx, stdout)) {
            return;
        }
    }

    // Check if this is a non-HTML content request
    if (std.mem.eql(u8, ctx.cmd, "plain") or
        std.mem.eql(u8, ctx.cmd, "snapshot") or
        std.mem.eql(u8, ctx.cmd, "patch") or
        std.mem.eql(u8, ctx.cmd, "atom") or
        std.mem.eql(u8, ctx.cmd, "rawdiff") or
        std.mem.eql(u8, ctx.cmd, "clone"))
    {
        // We need to buffer the content so we can determine MIME type first
        var content_buffer: std.ArrayList(u8) = .empty;
        defer content_buffer.deinit(ctx.allocator);

        // Call the handler to set MIME type and generate content
        try cmd.dispatch(ctx, content_buffer.writer(ctx.allocator));

        // Now output headers with correct MIME type
        try stdout.print("Content-Type: {s}\r\n", .{ctx.page.mimetype});

        // Add Content-Disposition header
        if (ctx.page.filename) |filename| {
            if (filename.len > 0) {
                // Use inline for images and PDFs (viewable in browser), attachment for others
                const disposition = if (std.mem.startsWith(u8, ctx.page.mimetype, "image/") or
                    std.mem.eql(u8, ctx.page.mimetype, "application/pdf") or
                    std.mem.eql(u8, ctx.page.mimetype, "text/plain") or
                    std.mem.eql(u8, ctx.page.mimetype, "text/html"))
                    "inline"
                else
                    "attachment";
                try stdout.print("Content-Disposition: {s}; filename=\"{s}\"\r\n", .{ disposition, filename });
            }
        }

        try stdout.writeAll("Cache-Control: no-cache, no-store\r\n");
        try stdout.writeAll("\r\n");

        // Output the content
        try stdout.writeAll(content_buffer.items);
        return;
    }

    // Generate HTML response
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(ctx.allocator);

    // Write HTTP headers
    try buffer.appendSlice(ctx.allocator, "Content-Type: text/html; charset=UTF-8\r\n");
    try buffer.appendSlice(ctx.allocator, "Cache-Control: no-cache, no-store\r\n");
    try buffer.appendSlice(ctx.allocator, "\r\n");

    // Generate HTML content
    try generateHtmlContent(ctx, buffer.writer(ctx.allocator));

    // Write to stdout
    try stdout.writeAll(buffer.items);

    // Update cache if enabled
    if (ctx.cfg.cache_enabled) {
        try cache.updateCache(ctx, buffer.items);
    }
}

fn generateHtmlContent(ctx: *gitweb.Context, writer: anytype) !void {
    // Write HTML header
    try html.writeHeader(ctx, writer);

    // Route to appropriate handler based on command
    try cmd.dispatch(ctx, writer);

    // Write HTML footer
    try html.writeFooter(ctx, writer);
}

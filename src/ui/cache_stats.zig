const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const cache = @import("../cache.zig");

pub fn cacheStats(ctx: *gitweb.Context, writer: anytype) !void {
    // Only allow cache stats if user is admin or cache debugging is enabled
    if (!ctx.cfg.enable_cache_stats) {
        try writer.writeAll("<div class='error'>Cache statistics are disabled</div>\n");
        return;
    }

    try writer.writeAll("<div class='cache-stats'>\n");
    try writer.writeAll("<h2>Cache Statistics</h2>\n");

    // Get cache statistics
    const stats = try cache.getCacheStats(ctx.allocator, ctx.cfg.cache_root);

    // General statistics
    try writer.writeAll("<div class='stats-summary'>\n");
    try writer.writeAll("<h3>Summary</h3>\n");
    try writer.writeAll("<table class='stats-table'>\n");

    try writer.print("<tr><th>Cache Enabled</th><td>{s}</td></tr>\n", .{if (ctx.cfg.cache_enabled) "Yes" else "No"});

    try writer.print("<tr><th>Cache Root</th><td>{s}</td></tr>\n", .{ctx.cfg.cache_root});

    try writer.print("<tr><th>Max Size</th><td>{}</td></tr>\n", .{if (ctx.cfg.cache_size > 0)
        try formatBytes(ctx.allocator, ctx.cfg.cache_size)
    else
        try ctx.allocator.dupe(u8, "Unlimited")});

    try writer.print("<tr><th>Current Size</th><td>{s}</td></tr>\n", .{try formatBytes(ctx.allocator, stats.size_bytes)});

    try writer.print("<tr><th>Entry Count</th><td>{}</td></tr>\n", .{stats.entry_count});

    try writer.print("<tr><th>Hit Rate</th><td>{d:.1}%</td></tr>\n", .{stats.hitRate() * 100});

    try writer.writeAll("</table>\n");
    try writer.writeAll("</div>\n");

    // Performance metrics
    try writer.writeAll("<div class='stats-performance'>\n");
    try writer.writeAll("<h3>Performance</h3>\n");
    try writer.writeAll("<table class='stats-table'>\n");

    try writer.print("<tr><th>Cache Hits</th><td>{}</td></tr>\n", .{stats.hits});
    try writer.print("<tr><th>Cache Misses</th><td>{}</td></tr>\n", .{stats.misses});
    try writer.print("<tr><th>Expired Entries</th><td>{}</td></tr>\n", .{stats.expired});
    try writer.print("<tr><th>Errors</th><td>{}</td></tr>\n", .{stats.errors});

    try writer.writeAll("</table>\n");
    try writer.writeAll("</div>\n");

    // TTL Configuration
    try writer.writeAll("<div class='stats-ttl'>\n");
    try writer.writeAll("<h3>TTL Configuration (minutes)</h3>\n");
    try writer.writeAll("<table class='stats-table'>\n");

    try writer.print("<tr><th>Dynamic Content</th><td>{}</td></tr>\n", .{ctx.cfg.cache_dynamic_ttl});
    try writer.print("<tr><th>Static Content</th><td>{}</td></tr>\n", .{if (ctx.cfg.cache_static_ttl < 0)
        try ctx.allocator.dupe(u8, "Never expires")
    else if (ctx.cfg.cache_static_ttl == 0)
        try ctx.allocator.dupe(u8, "Disabled")
    else
        try std.fmt.allocPrint(ctx.allocator, "{}", .{ctx.cfg.cache_static_ttl})});
    try writer.print("<tr><th>Repository Pages</th><td>{}</td></tr>\n", .{ctx.cfg.cache_repo_ttl});
    try writer.print("<tr><th>Repository List</th><td>{}</td></tr>\n", .{ctx.cfg.cache_root_ttl});
    try writer.print("<tr><th>About Pages</th><td>{}</td></tr>\n", .{ctx.cfg.cache_about_ttl});
    try writer.print("<tr><th>Snapshots</th><td>{}</td></tr>\n", .{ctx.cfg.cache_snapshot_ttl});
    try writer.print("<tr><th>Repository Scan</th><td>{}</td></tr>\n", .{ctx.cfg.cache_scanrc_ttl});

    try writer.writeAll("</table>\n");
    try writer.writeAll("</div>\n");

    // Cache actions
    try writer.writeAll("<div class='cache-actions'>\n");
    try writer.writeAll("<h3>Actions</h3>\n");

    try writer.writeAll("<form method='post' action='?cmd=cache-clear'>\n");
    try writer.writeAll("<button type='submit' onclick=\"return confirm('Are you sure you want to clear the entire cache?')\">Clear Cache</button>\n");
    try writer.writeAll("</form>\n");

    try writer.writeAll("<form method='post' action='?cmd=cache-invalidate' class='cache-invalidate-form'>\n");
    try writer.writeAll("<input type='text' name='pattern' placeholder='Pattern to invalidate (e.g., repo_name)' />\n");
    try writer.writeAll("<button type='submit'>Invalidate Matching</button>\n");
    try writer.writeAll("</form>\n");

    try writer.writeAll("</div>\n");

    try writer.writeAll("</div>\n");
}

fn formatBytes(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var size = @as(f64, @floatFromInt(bytes));
    var unit_idx: usize = 0;

    while (size >= 1024 and unit_idx < units.len - 1) {
        size /= 1024;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.allocPrint(allocator, "{} {s}", .{ bytes, units[unit_idx] });
    } else {
        return std.fmt.allocPrint(allocator, "{d:.2} {s}", .{ size, units[unit_idx] });
    }
}

pub fn cacheClear(ctx: *gitweb.Context, writer: anytype) !void {
    _ = writer;

    if (!ctx.cfg.enable_cache_stats) {
        return error.Unauthorized;
    }

    if (!std.mem.eql(u8, ctx.env.request_method, "POST")) {
        return error.MethodNotAllowed;
    }

    try cache.clearCache(ctx.allocator, ctx.cfg.cache_root);

    // Redirect back to stats page
    ctx.page.status = 303;
    ctx.page.statusmsg = "See Other";
    // The redirect will be handled by the main handler
}

pub fn cacheInvalidate(ctx: *gitweb.Context, writer: anytype) !void {
    _ = writer;

    if (!ctx.cfg.enable_cache_stats) {
        return error.Unauthorized;
    }

    if (!std.mem.eql(u8, ctx.env.request_method, "POST")) {
        return error.MethodNotAllowed;
    }

    const pattern = ctx.query.get("pattern") orelse return error.MissingParameter;

    try cache.invalidateCache(ctx.allocator, ctx.cfg.cache_root, pattern);

    // Redirect back to stats page
    ctx.page.status = 303;
    ctx.page.statusmsg = "See Other";
}

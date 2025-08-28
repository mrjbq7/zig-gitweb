const std = @import("std");
const gitweb = @import("gitweb.zig");

pub fn tryServeFromCache(ctx: *gitweb.Context, writer: anytype) !bool {
    // Generate cache key based on request
    const cache_key = try generateCacheKey(ctx);
    defer ctx.allocator.free(cache_key);

    // Build cache file path
    const cache_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.cfg.cache_root, cache_key });
    defer ctx.allocator.free(cache_path);

    // Try to open cache file
    const file = std.fs.openFileAbsolute(cache_path, .{}) catch {
        return false; // Cache miss
    };
    defer file.close();

    // Check if cache is still valid
    const stat = try file.stat();
    const now = std.time.timestamp();
    const ttl = getCacheTtl(ctx);

    if (now - stat.mtime > ttl) {
        return false; // Cache expired
    }

    // Serve from cache
    const content = try file.readToEndAlloc(ctx.allocator, std.math.maxInt(usize));
    defer ctx.allocator.free(content);

    try writer.writeAll(content);
    return true; // Cache hit
}

pub fn updateCache(ctx: *gitweb.Context, content: []const u8) !void {
    // Generate cache key
    const cache_key = try generateCacheKey(ctx);
    defer ctx.allocator.free(cache_key);

    // Build cache file path
    const cache_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.cfg.cache_root, cache_key });
    defer ctx.allocator.free(cache_path);

    // Ensure cache directory exists
    const dir_path = std.fs.path.dirname(cache_path) orelse return;
    try std.fs.makeDirAbsolute(dir_path);

    // Write to temporary file first
    const tmp_path = try std.fmt.allocPrint(ctx.allocator, "{s}.tmp", .{cache_path});
    defer ctx.allocator.free(tmp_path);

    const file = try std.fs.createFileAbsolute(tmp_path, .{});
    defer file.close();

    try file.writeAll(content);

    // Atomically rename to final location
    try std.fs.renameAbsolute(tmp_path, cache_path);
}

fn generateCacheKey(ctx: *gitweb.Context) ![]const u8 {
    var hasher = std.hash.Wyhash.init(0);

    // Hash the request components
    if (ctx.repo) |repo| {
        hasher.update(repo.url);
    }
    hasher.update(ctx.cmd);
    hasher.update(ctx.env.query_string orelse "");

    const hash = hasher.final();
    return std.fmt.allocPrint(ctx.allocator, "{x}", .{hash});
}

fn getCacheTtl(ctx: *gitweb.Context) i64 {
    // Determine TTL based on page type
    if (std.mem.eql(u8, ctx.cmd, "about")) {
        return @intCast(ctx.cfg.cache_about_ttl * 60);
    } else if (std.mem.eql(u8, ctx.cmd, "snapshot")) {
        return @intCast(ctx.cfg.cache_snapshot_ttl * 60);
    } else if (ctx.repo != null) {
        return @intCast(ctx.cfg.cache_repo_ttl * 60);
    } else {
        return @intCast(ctx.cfg.cache_root_ttl * 60);
    }
}

pub const CacheLock = struct {
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    locked: bool,

    pub fn init(allocator: std.mem.Allocator, cache_path: []const u8) !CacheLock {
        const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{cache_path});
        return CacheLock{
            .allocator = allocator,
            .lock_path = lock_path,
            .locked = false,
        };
    }

    pub fn acquire(self: *CacheLock, max_attempts: u32) !void {
        var attempts: u32 = 0;
        while (attempts < max_attempts) : (attempts += 1) {
            // Try to create lock file exclusively
            const file = std.fs.createFileAbsolute(self.lock_path, .{ .exclusive = true }) catch |err| {
                if (err == error.PathAlreadyExists) {
                    // Lock is held by another process
                    std.time.sleep(100 * std.time.ns_per_ms); // Sleep 100ms
                    continue;
                }
                return err;
            };
            file.close();
            self.locked = true;
            return;
        }
        return error.LockTimeout;
    }

    pub fn release(self: *CacheLock) void {
        if (self.locked) {
            std.fs.deleteFileAbsolute(self.lock_path) catch {};
            self.locked = false;
        }
    }

    pub fn deinit(self: *CacheLock) void {
        self.release();
        self.allocator.free(self.lock_path);
    }
};

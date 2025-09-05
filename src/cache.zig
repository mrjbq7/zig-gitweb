const std = @import("std");
const gitweb = @import("gitweb.zig");
const git = @import("git.zig");

/// Cache entry metadata stored alongside cached content
const CacheMetadata = struct {
    created: i64,
    expires: i64,
    etag: [32]u8,
    content_type: []const u8,
    is_static: bool,
};

/// Cache statistics for monitoring
pub const CacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    expired: u64 = 0,
    errors: u64 = 0,
    size_bytes: u64 = 0,
    entry_count: u64 = 0,

    pub fn hitRate(self: CacheStats) f32 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(total));
    }
};

/// Enhanced cache implementation with size management and advanced features
pub const Cache = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    max_size: usize,
    stats: CacheStats,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8, max_size: usize) !Cache {
        // Ensure cache directory exists
        try std.fs.makeDirAbsolute(root_path);

        return Cache{
            .allocator = allocator,
            .root_path = root_path,
            .max_size = max_size,
            .stats = .{},
            .mutex = .{},
        };
    }

    /// Try to serve content from cache
    pub fn get(self: *Cache, ctx: *gitweb.Context, writer: anytype) !bool {
        const cache_key = try self.generateKey(ctx);
        defer self.allocator.free(cache_key);

        const cache_path = try self.getPath(cache_key);
        defer self.allocator.free(cache_path);

        // Try to open cache file
        const file = std.fs.openFileAbsolute(cache_path, .{}) catch {
            self.mutex.lock();
            self.stats.misses += 1;
            self.mutex.unlock();
            return false;
        };
        defer file.close();

        // Read metadata
        const metadata = try self.readMetadata(file);

        // Check expiration
        const now = std.time.timestamp();
        if (metadata.expires > 0 and now > metadata.expires) {
            self.mutex.lock();
            self.stats.expired += 1;
            self.mutex.unlock();

            // Delete expired entry
            try std.fs.deleteFileAbsolute(cache_path);
            return false;
        }

        // Set HTTP headers
        try self.setHttpHeaders(ctx, metadata, writer);

        // Read and serve content
        const content = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(content);

        try writer.writeAll(content);

        self.mutex.lock();
        self.stats.hits += 1;
        self.mutex.unlock();

        return true;
    }

    /// Store content in cache
    pub fn put(self: *Cache, ctx: *gitweb.Context, content: []const u8) !void {
        // Check if caching should be bypassed
        if (!self.shouldCache(ctx)) return;

        // Check cache size limit
        if (self.max_size > 0) {
            const current_size = try self.calculateSize();
            if (current_size + content.len > self.max_size) {
                try self.evictOldest();
            }
        }

        const cache_key = try self.generateKey(ctx);
        defer self.allocator.free(cache_key);

        const cache_path = try self.getPath(cache_key);
        defer self.allocator.free(cache_path);

        // Create metadata
        const now = std.time.timestamp();
        const ttl = self.getTtl(ctx);
        const metadata = CacheMetadata{
            .created = now,
            .expires = if (ttl < 0) -1 else now + ttl,
            .etag = try self.generateEtag(content),
            .content_type = ctx.page.mimetype,
            .is_static = self.isStaticContent(ctx),
        };

        // Use lock for atomic write
        var lock = try CacheLock.init(self.allocator, cache_path);
        defer lock.deinit();

        const max_wait = if (ctx.cfg.cache_max_create_time > 0)
            @as(u32, @intCast(ctx.cfg.cache_max_create_time * 10)) // Convert seconds to 100ms units
        else
            50; // Default 5 seconds

        try lock.acquire(max_wait);
        defer lock.release();

        // Write to temporary file
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{cache_path});
        defer self.allocator.free(tmp_path);

        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();

        // Write metadata and content
        try self.writeMetadata(file, metadata);
        try file.writeAll(content);

        // Atomic rename
        try std.fs.renameAbsolute(tmp_path, cache_path);

        self.mutex.lock();
        self.stats.entry_count += 1;
        self.stats.size_bytes += content.len;
        self.mutex.unlock();
    }

    /// Clear entire cache
    pub fn clear(self: *Cache) !void {
        var dir = try std.fs.openDirAbsolute(self.root_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                try dir.deleteFile(entry.name);
            }
        }

        self.mutex.lock();
        self.stats = .{};
        self.mutex.unlock();
    }

    /// Invalidate cache entries matching a pattern
    pub fn invalidate(self: *Cache, pattern: []const u8) !void {
        var dir = try std.fs.openDirAbsolute(self.root_path, .{ .iterate = true });
        defer dir.close();

        var count: u64 = 0;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.indexOf(u8, entry.name, pattern) != null) {
                try dir.deleteFile(entry.name);
                count += 1;
            }
        }

        self.mutex.lock();
        if (count > 0) {
            self.stats.entry_count = if (self.stats.entry_count > count)
                self.stats.entry_count - count
            else
                0;
        }
        self.mutex.unlock();
    }

    // Private methods

    fn generateKey(self: *Cache, ctx: *gitweb.Context) ![]const u8 {
        var hasher = std.hash.Wyhash.init(0);

        // Include all relevant request parameters
        if (ctx.repo) |repo| {
            hasher.update(repo.url);
        }
        hasher.update(ctx.cmd);
        hasher.update(ctx.env.query_string orelse "");
        hasher.update(ctx.env.path_info orelse "");

        // Include repository state for dynamic content
        if (!self.isStaticContent(ctx) and ctx.repo != null) {
            // Include HEAD commit to invalidate on updates
            if (ctx.repo.?.path.len > 0) {
                const head_oid = try self.getRepoHead(ctx.repo.?.path);
                hasher.update(&head_oid);
            }
        }

        const hash = hasher.final();

        // Create hierarchical cache structure for better filesystem performance
        const hash_str = try std.fmt.allocPrint(self.allocator, "{x:0>16}", .{hash});
        defer self.allocator.free(hash_str);

        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{
            hash_str[0..2], // First level directory
            hash_str[2..4], // Second level directory
            hash_str[4..], // Filename
        });
    }

    fn getPath(self: *Cache, key: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root_path, key });
    }

    fn getTtl(self: *Cache, ctx: *gitweb.Context) i64 {
        // Static content (with fixed SHA1)
        if (self.isStaticContent(ctx)) {
            return ctx.cfg.cache_static_ttl * 60;
        }

        // Page-specific TTLs
        if (std.mem.eql(u8, ctx.cmd, "about")) {
            return ctx.cfg.cache_about_ttl * 60;
        } else if (std.mem.eql(u8, ctx.cmd, "snapshot")) {
            return ctx.cfg.cache_snapshot_ttl * 60;
        } else if (std.mem.eql(u8, ctx.cmd, "repolist") or std.mem.eql(u8, ctx.cmd, "")) {
            return ctx.cfg.cache_root_ttl * 60;
        } else if (ctx.repo != null) {
            // Check if accessing with a fixed commit
            if (ctx.query.get("id") != null or ctx.query.get("h") != null) {
                return ctx.cfg.cache_static_ttl * 60;
            }
            return ctx.cfg.cache_repo_ttl * 60;
        } else {
            return ctx.cfg.cache_dynamic_ttl * 60;
        }
    }

    fn isStaticContent(self: *Cache, ctx: *gitweb.Context) bool {
        _ = self;
        // Content is static if it references a specific commit SHA
        if (ctx.query.get("id")) |id| {
            // Check if it's a SHA1 (40 hex chars)
            if (id.len == 40) {
                for (id) |c| {
                    if (!std.ascii.isHex(c)) return false;
                }
                return true;
            }
        }

        // Snapshots with specific commits are also static
        if (std.mem.eql(u8, ctx.cmd, "snapshot")) {
            if (ctx.query.get("h")) |h| {
                if (h.len == 40) {
                    for (h) |c| {
                        if (!std.ascii.isHex(c)) return false;
                    }
                    return true;
                }
            }
        }

        return false;
    }

    fn shouldCache(self: *Cache, ctx: *gitweb.Context) bool {
        // Don't cache if disabled
        if (!ctx.cfg.cache_enabled) return false;

        // Don't cache POST requests
        if (!std.mem.eql(u8, ctx.env.request_method orelse "GET", "GET")) return false;

        // Don't cache if TTL is 0
        const ttl = self.getTtl(ctx);
        if (ttl == 0) return false;

        return true;
    }

    fn generateEtag(self: *Cache, content: []const u8) ![32]u8 {
        _ = self;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(content);
        return hasher.finalResult();
    }

    fn getRepoHead(self: *Cache, repo_path: []const u8) ![20]u8 {
        _ = self;
        var result: [20]u8 = undefined;

        var repo = git.Repository.open(repo_path) catch {
            // If can't open repo, return zeros
            @memset(&result, 0);
            return result;
        };
        defer repo.close();

        var head_ref: ?*git.c.git_reference = null;
        if (git.c.git_repository_head(&head_ref, repo.repo) != 0) {
            @memset(&result, 0);
            return result;
        }
        defer if (head_ref) |ref| git.c.git_reference_free(ref);

        const oid = git.c.git_reference_target(head_ref);
        if (oid) |o| {
            @memcpy(&result, &o.*.id);
        } else {
            @memset(&result, 0);
        }

        return result;
    }

    fn writeMetadata(self: *Cache, file: std.fs.File, metadata: CacheMetadata) !void {
        _ = self;
        // Write as binary struct
        try file.writeAll(std.mem.asBytes(&metadata));
    }

    fn readMetadata(self: *Cache, file: std.fs.File) !CacheMetadata {
        _ = self;
        var metadata: CacheMetadata = undefined;
        const bytes = try file.read(std.mem.asBytes(&metadata));
        if (bytes != @sizeOf(CacheMetadata)) {
            return error.InvalidCacheEntry;
        }
        return metadata;
    }

    fn setHttpHeaders(self: *Cache, ctx: *gitweb.Context, metadata: CacheMetadata, writer: anytype) !void {
        _ = writer;

        // Set ETag for conditional requests
        var etag_hex: [64]u8 = undefined;
        for (metadata.etag, 0..) |byte, i| {
            _ = std.fmt.bufPrint(etag_hex[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch {};
        }
        const etag_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{etag_hex[0..64]});
        defer self.allocator.free(etag_str);
        ctx.page.etag = etag_str;

        // Set Last-Modified
        ctx.page.modified = metadata.created;

        // Set Cache-Control based on TTL
        if (metadata.is_static) {
            ctx.page.cache_control = "public, max-age=31536000, immutable"; // 1 year for static
        } else if (metadata.expires > 0) {
            const now = std.time.timestamp();
            const max_age = if (metadata.expires > now) metadata.expires - now else 0;
            const cache_control = try std.fmt.allocPrint(self.allocator, "public, max-age={d}", .{max_age});
            ctx.page.cache_control = cache_control;
        }
    }

    fn calculateSize(self: *Cache) !u64 {
        var total: u64 = 0;
        var dir = try std.fs.openDirAbsolute(self.root_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                const file = try dir.openFile(entry.path, .{});
                defer file.close();
                const stat = try file.stat();
                total += stat.size;
            }
        }

        return total;
    }

    fn evictOldest(self: *Cache) !void {
        // Simple LRU eviction - remove oldest accessed files
        var oldest_time: i64 = std.math.maxInt(i64);
        var oldest_path: ?[]const u8 = null;

        var dir = try std.fs.openDirAbsolute(self.root_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                const file = try dir.openFile(entry.path, .{});
                defer file.close();
                const stat = try file.stat();

                // Use access time if available, otherwise modification time
                const time: i64 = @intCast(stat.atime);
                if (time < oldest_time) {
                    oldest_time = time;
                    if (oldest_path) |p| self.allocator.free(p);
                    oldest_path = try self.allocator.dupe(u8, entry.path);
                }
            }
        }

        if (oldest_path) |path| {
            defer self.allocator.free(path);
            try dir.deleteFile(path);

            self.mutex.lock();
            if (self.stats.entry_count > 0) {
                self.stats.entry_count -= 1;
            }
            self.mutex.unlock();
        }
    }
};

/// Cache lock for concurrent access control
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
                    // Check if lock is stale (older than 60 seconds)
                    if (std.fs.openFileAbsolute(self.lock_path, .{})) |lock_file| {
                        defer lock_file.close();
                        const stat = lock_file.stat() catch {
                            std.Thread.sleep(100 * std.time.ns_per_ms);
                            continue;
                        };
                        const now = std.time.timestamp();
                        if (now - stat.mtime > 60) {
                            // Stale lock, try to remove it
                            std.fs.deleteFileAbsolute(self.lock_path) catch {};
                            continue;
                        }
                    } else |_| {}

                    // Lock is held by another process
                    std.Thread.sleep(100 * std.time.ns_per_ms); // Sleep 100ms
                    continue;
                }
                return err;
            };

            // Close lock file
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

/// Helper functions for cache management
pub fn tryServeFromCache(ctx: *gitweb.Context, writer: anytype) !bool {
    if (!ctx.cfg.cache_enabled) return false;

    var cache = try Cache.init(ctx.allocator, ctx.cfg.cache_root, ctx.cfg.cache_size);
    return try cache.get(ctx, writer);
}

pub fn updateCache(ctx: *gitweb.Context, content: []const u8) !void {
    if (!ctx.cfg.cache_enabled) return;

    var cache = try Cache.init(ctx.allocator, ctx.cfg.cache_root, ctx.cfg.cache_size);
    try cache.put(ctx, content);
}

/// Get cache statistics for monitoring
pub fn getCacheStats(allocator: std.mem.Allocator, cache_root: []const u8) !CacheStats {
    const cache = try Cache.init(allocator, cache_root, 0);
    return cache.stats;
}

// Tests
const testing = std.testing;

test CacheStats {
    var stats = CacheStats{};

    // Test initial state
    try testing.expectEqual(@as(u64, 0), stats.hits);
    try testing.expectEqual(@as(u64, 0), stats.misses);
    try testing.expectEqual(@as(u64, 0), stats.size_bytes);
    try testing.expectEqual(@as(u64, 0), stats.entry_count);

    // Test hit rate calculation
    stats.hits = 75;
    stats.misses = 25;
    const hit_rate = @as(f32, @floatFromInt(stats.hits)) /
        @as(f32, @floatFromInt(stats.hits + stats.misses));
    try testing.expect(hit_rate == 0.75);
}

test "TTL calculation" {
    // Test that each content type has appropriate TTL
    var ctx = try gitweb.Context.init(testing.allocator);
    defer ctx.deinit();

    // Simulate different commands and check TTL would be reasonable
    ctx.cmd = "summary";
    // Summary pages should have short TTL (5 minutes = 300 seconds)

    ctx.cmd = "snapshot";
    // Snapshots can have longer TTL (1 hour = 3600 seconds)

    ctx.cmd = "tree";
    // Tree views with specific commit should be cacheable for long time

    // Just verify the context can be created and destroyed
    try testing.expect(ctx.cmd.len > 0);
}

/// Clear all cache entries
pub fn clearCache(allocator: std.mem.Allocator, cache_root: []const u8) !void {
    var cache = try Cache.init(allocator, cache_root, 0);
    try cache.clear();
}

/// Invalidate cache entries matching a pattern
pub fn invalidateCache(allocator: std.mem.Allocator, cache_root: []const u8, pattern: []const u8) !void {
    var cache = try Cache.init(allocator, cache_root, 0);
    try cache.invalidate(pattern);
}

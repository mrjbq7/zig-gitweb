const std = @import("std");
const gitweb = @import("gitweb.zig");
const html = @import("html.zig");

pub const UrlBuilder = struct {
    allocator: std.mem.Allocator,
    base: []const u8,
    params: std.ArrayList(struct { key: []const u8, value: []const u8 }),

    pub fn init(allocator: std.mem.Allocator, base: []const u8) UrlBuilder {
        return .{
            .allocator = allocator,
            .base = base,
            .params = std.ArrayList(struct { key: []const u8, value: []const u8 }){
                .items = &.{},
                .capacity = 0,
            },
        };
    }

    pub fn deinit(self: *UrlBuilder) void {
        self.params.deinit(self.allocator);
    }

    pub fn addParam(self: *UrlBuilder, key: []const u8, value: []const u8) !void {
        try self.params.append(self.allocator, .{ .key = key, .value = value });
    }

    pub fn build(self: *UrlBuilder) ![]const u8 {
        var buffer = std.ArrayList(u8){
            .items = &.{},
            .capacity = 0,
        };
        defer buffer.deinit(self.allocator);

        try buffer.appendSlice(self.allocator, self.base);

        for (self.params.items, 0..) |param, i| {
            const separator = if (i == 0) "?" else "&";
            try buffer.appendSlice(self.allocator, separator);
            try buffer.appendSlice(self.allocator, param.key);
            try buffer.append(self.allocator, '=');
            try urlEncode(&buffer, param.value);
        }

        return buffer.toOwnedSlice(self.allocator);
    }

    fn urlEncode(buffer: *std.ArrayList(u8), text: []const u8) !void {
        for (text) |char| {
            if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~') {
                try buffer.append(buffer.allocator, char);
            } else {
                try buffer.appendSlice(buffer.allocator, std.fmt.allocPrint(buffer.allocator, "%{X:0>2}", .{char}) catch unreachable);
            }
        }
    }
};

pub fn repoUrl(ctx: *gitweb.Context, repo: *gitweb.Repo, page: ?[]const u8) ![]const u8 {
    var builder = UrlBuilder.init(ctx.allocator, ctx.cfg.virtual_root);
    defer builder.deinit();

    try builder.addParam("r", repo.url);
    if (page) |p| {
        try builder.addParam("p", p);
    }

    return builder.build();
}

pub fn pageUrl(ctx: *gitweb.Context, page: []const u8, params: ?std.StringHashMap([]const u8)) ![]const u8 {
    var builder = UrlBuilder.init(ctx.allocator, ctx.cfg.virtual_root);
    defer builder.deinit();

    try builder.addParam("p", page);

    if (params) |p| {
        var iter = p.iterator();
        while (iter.next()) |entry| {
            try builder.addParam(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return builder.build();
}

pub fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return "";

    var total_len: usize = 0;
    for (parts, 0..) |part, i| {
        total_len += part.len;
        if (i < parts.len - 1) {
            total_len += 1; // for '/'
        }
    }

    var result = try allocator.alloc(u8, total_len);
    var offset: usize = 0;

    for (parts, 0..) |part, i| {
        @memcpy(result[offset..][0..part.len], part);
        offset += part.len;

        if (i < parts.len - 1) {
            result[offset] = '/';
            offset += 1;
        }
    }

    return result;
}

pub fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parts = std.ArrayList([]const u8){
        .items = &.{},
        .capacity = 0,
    };
    defer parts.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, path, "/");
    while (iter.next()) |part| {
        if (std.mem.eql(u8, part, ".")) {
            continue;
        } else if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) {
                _ = parts.pop();
            }
        } else if (part.len > 0) {
            try parts.append(allocator, part);
        }
    }

    return joinPath(allocator, parts.items);
}

pub fn isPathSafe(path: []const u8) bool {
    // Check for path traversal attempts
    if (std.mem.indexOf(u8, path, "..") != null) return false;

    // Check for absolute paths
    if (path.len > 0 and path[0] == '/') return false;

    // Check for special characters that might be dangerous
    for (path) |c| {
        if (c == 0 or c == '\n' or c == '\r') return false;
    }

    return true;
}

pub fn expandTilde(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) {
        return allocator.dupe(u8, path);
    }

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        return allocator.dupe(u8, path);
    };
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
}

pub fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

pub fn isDirectory(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    const stat = file.stat() catch return false;
    return stat.kind == .directory;
}

pub fn isGitRepository(path: []const u8) bool {
    const allocator = std.heap.page_allocator;

    // Check for .git directory
    const git_dir = std.fmt.allocPrint(allocator, "{s}/.git", .{path}) catch return false;
    defer allocator.free(git_dir);

    if (isDirectory(git_dir)) return true;

    // Check for bare repository (has refs, objects, HEAD)
    const refs = std.fmt.allocPrint(allocator, "{s}/refs", .{path}) catch return false;
    defer allocator.free(refs);

    const objects = std.fmt.allocPrint(allocator, "{s}/objects", .{path}) catch return false;
    defer allocator.free(objects);

    const head = std.fmt.allocPrint(allocator, "{s}/HEAD", .{path}) catch return false;
    defer allocator.free(head);

    return isDirectory(refs) and isDirectory(objects) and fileExists(head);
}

pub const RepoInfo = struct {
    path: []const u8,
    name: []const u8,
    description: []const u8,
    owner: []const u8,
    last_modified: i64,
    is_bare: bool,
};

pub fn getRepoInfo(allocator: std.mem.Allocator, path: []const u8) !RepoInfo {
    var info = RepoInfo{
        .path = try allocator.dupe(u8, path),
        .name = std.fs.path.basename(path),
        .description = "",
        .owner = "",
        .last_modified = 0,
        .is_bare = false,
    };

    // Check if bare repository
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{path});
    defer allocator.free(git_dir);

    const repo_root = if (isDirectory(git_dir)) git_dir else path;
    info.is_bare = !isDirectory(git_dir);

    // Read description file
    const desc_path = try std.fmt.allocPrint(allocator, "{s}/description", .{repo_root});
    defer allocator.free(desc_path);

    if (std.fs.openFileAbsolute(desc_path, .{})) |file| {
        defer file.close();
        const content = file.readToEndAlloc(allocator, 1024) catch "";
        info.description = std.mem.trim(u8, content, " \t\r\n");
    } else |_| {
        info.description = "Unnamed repository; edit this file 'description' to name the repository.";
    }

    // Get last modified time from HEAD
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{repo_root});
    defer allocator.free(head_path);

    if (std.fs.openFileAbsolute(head_path, .{})) |file| {
        defer file.close();
        const stat = file.stat() catch undefined;
        info.last_modified = @intCast(stat.mtime);
    } else |_| {}

    return info;
}

pub fn getMimeType(filename: []const u8) []const u8 {
    const ext = std.fs.path.extension(filename);

    if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) return "text/html";
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".xml")) return "application/xml";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain";
    if (std.mem.eql(u8, ext, ".md")) return "text/markdown";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, ext, ".zip")) return "application/zip";
    if (std.mem.eql(u8, ext, ".tar")) return "application/x-tar";
    if (std.mem.eql(u8, ext, ".gz")) return "application/gzip";
    if (std.mem.eql(u8, ext, ".bz2")) return "application/x-bzip2";
    if (std.mem.eql(u8, ext, ".xz")) return "application/x-xz";
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h")) return "text/x-c";
    if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc")) return "text/x-c++";
    if (std.mem.eql(u8, ext, ".py")) return "text/x-python";
    if (std.mem.eql(u8, ext, ".rs")) return "text/x-rust";
    if (std.mem.eql(u8, ext, ".go")) return "text/x-go";
    if (std.mem.eql(u8, ext, ".zig")) return "text/x-zig";
    if (std.mem.eql(u8, ext, ".sh")) return "text/x-shellscript";

    return "application/octet-stream";
}

pub fn isBinaryContent(content: []const u8) bool {
    // Check for null bytes or other non-text characters
    for (content[0..@min(8192, content.len)]) |byte| {
        if (byte == 0) return true;
        if (byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') {
            return true;
        }
    }
    return false;
}

pub fn sanitizeHtml(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var output = std.ArrayList(u8){
        .items = &.{},
        .capacity = 0,
    };
    defer output.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '&' => try output.appendSlice(allocator, "&amp;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            '\'' => try output.appendSlice(allocator, "&#39;"),
            else => try output.append(allocator, c),
        }
    }

    return output.toOwnedSlice(allocator);
}

pub fn truncateString(str: []const u8, max_len: usize, suffix: []const u8) []const u8 {
    if (str.len <= max_len) return str;

    const truncate_at = max_len - suffix.len;
    if (truncate_at <= 0) return suffix;

    // Try to break at word boundary
    var break_at = truncate_at;
    while (break_at > 0 and !std.ascii.isWhitespace(str[break_at])) {
        break_at -= 1;
    }

    if (break_at == 0) break_at = truncate_at;

    return str[0..break_at];
}

test "normalizePath" {
    const allocator = std.testing.allocator;

    const result1 = try normalizePath(allocator, "foo/../bar");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("bar", result1);

    const result2 = try normalizePath(allocator, "./foo/./bar");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("foo/bar", result2);
}

test "isPathSafe" {
    try std.testing.expect(isPathSafe("foo/bar"));
    try std.testing.expect(!isPathSafe("../etc/passwd"));
    try std.testing.expect(!isPathSafe("/etc/passwd"));
}

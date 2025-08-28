const std = @import("std");
const gitweb = @import("gitweb.zig");

pub fn parseDate(str: []const u8, default_value: i64) i64 {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    if (trimmed.len == 0) return default_value;

    const timestamp = std.fmt.parseInt(i64, trimmed, 10) catch {
        // Try to parse as RFC2822 or ISO8601
        return default_value;
    };

    return timestamp;
}

pub fn parseBool(str: []const u8) bool {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");

    if (std.mem.eql(u8, trimmed, "1") or
        std.mem.eql(u8, trimmed, "true") or
        std.mem.eql(u8, trimmed, "yes") or
        std.mem.eql(u8, trimmed, "on"))
    {
        return true;
    }

    return false;
}

pub fn parseSize(str: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    if (trimmed.len == 0) return null;

    var value = trimmed;
    var multiplier: u64 = 1;

    if (std.mem.endsWith(u8, trimmed, "K") or std.mem.endsWith(u8, trimmed, "k")) {
        value = trimmed[0 .. trimmed.len - 1];
        multiplier = 1024;
    } else if (std.mem.endsWith(u8, trimmed, "M") or std.mem.endsWith(u8, trimmed, "m")) {
        value = trimmed[0 .. trimmed.len - 1];
        multiplier = 1024 * 1024;
    } else if (std.mem.endsWith(u8, trimmed, "G") or std.mem.endsWith(u8, trimmed, "g")) {
        value = trimmed[0 .. trimmed.len - 1];
        multiplier = 1024 * 1024 * 1024;
    }

    const num = std.fmt.parseInt(u64, value, 10) catch return null;
    return num * multiplier;
}

pub fn parseOctalMode(str: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    return std.fmt.parseInt(u32, trimmed, 8) catch null;
}

pub fn parseHexColor(str: []const u8) ?u32 {
    var trimmed = std.mem.trim(u8, str, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '#') {
        trimmed = trimmed[1..];
    }

    if (trimmed.len == 3) {
        // Short form #RGB -> #RRGGBB
        const r = std.fmt.parseInt(u8, trimmed[0..1], 16) catch return null;
        const g = std.fmt.parseInt(u8, trimmed[1..2], 16) catch return null;
        const b = std.fmt.parseInt(u8, trimmed[2..3], 16) catch return null;
        return (@as(u32, r) << 20) | (@as(u32, r) << 16) |
            (@as(u32, g) << 12) | (@as(u32, g) << 8) |
            (@as(u32, b) << 4) | @as(u32, b);
    } else if (trimmed.len == 6) {
        return std.fmt.parseInt(u32, trimmed, 16) catch null;
    }

    return null;
}

pub fn extractEmail(author_line: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, author_line, "<") orelse return null;
    const end = std.mem.indexOf(u8, author_line[start..], ">") orelse return null;
    return author_line[start + 1 .. start + end];
}

pub fn extractName(author_line: []const u8) []const u8 {
    const email_start = std.mem.indexOf(u8, author_line, "<") orelse return author_line;
    return std.mem.trim(u8, author_line[0..email_start], " \t");
}

pub fn parseCommitMessage(message: []const u8) struct { subject: []const u8, body: []const u8 } {
    const first_newline = std.mem.indexOf(u8, message, "\n") orelse message.len;
    const subject = std.mem.trim(u8, message[0..first_newline], " \t\r\n");

    var body_start = first_newline;
    while (body_start < message.len and (message[body_start] == '\n' or message[body_start] == '\r')) {
        body_start += 1;
    }

    const body = if (body_start < message.len) message[body_start..] else "";

    return .{ .subject = subject, .body = body };
}

pub fn formatFileSize(size: u64, writer: anytype) !void {
    if (size < 1024) {
        try writer.print("{d} B", .{size});
    } else if (size < 1024 * 1024) {
        try writer.print("{d:.1} KB", .{@as(f64, @floatFromInt(size)) / 1024.0});
    } else if (size < 1024 * 1024 * 1024) {
        try writer.print("{d:.1} MB", .{@as(f64, @floatFromInt(size)) / (1024.0 * 1024.0)});
    } else {
        try writer.print("{d:.1} GB", .{@as(f64, @floatFromInt(size)) / (1024.0 * 1024.0 * 1024.0)});
    }
}

pub fn formatTimestamp(timestamp: i64, writer: anytype) !void {
    // Simple ISO format for now
    const epoch_seconds = @as(u64, @intCast(timestamp));
    const year = @divFloor(epoch_seconds, 365 * 24 * 3600) + 1970;
    try writer.print("{d}-01-01 00:00:00", .{year});
}

pub fn formatDuration(seconds: u64, writer: anytype) !void {
    if (seconds < 60) {
        try writer.print("{d}s", .{seconds});
    } else if (seconds < 3600) {
        try writer.print("{d}m {d}s", .{ seconds / 60, seconds % 60 });
    } else if (seconds < 86400) {
        const hours = seconds / 3600;
        const minutes = (seconds % 3600) / 60;
        try writer.print("{d}h {d}m", .{ hours, minutes });
    } else {
        const days = seconds / 86400;
        const hours = (seconds % 86400) / 3600;
        try writer.print("{d}d {d}h", .{ days, hours });
    }
}

pub fn stripPrefix(str: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, str, prefix)) {
        return str[prefix.len..];
    }
    return str;
}

pub fn stripSuffix(str: []const u8, suffix: []const u8) []const u8 {
    if (std.mem.endsWith(u8, str, suffix)) {
        return str[0 .. str.len - suffix.len];
    }
    return str;
}

pub fn normalizeRefName(ref: []const u8) []const u8 {
    var normalized = ref;
    normalized = stripPrefix(normalized, "refs/");
    normalized = stripPrefix(normalized, "heads/");
    normalized = stripPrefix(normalized, "tags/");
    normalized = stripPrefix(normalized, "remotes/");
    return normalized;
}

pub fn isValidSha1(str: []const u8) bool {
    if (str.len != 40) return false;

    for (str) |c| {
        if (!std.ascii.isHex(c)) return false;
    }

    return true;
}

pub fn isValidSha256(str: []const u8) bool {
    if (str.len != 64) return false;

    for (str) |c| {
        if (!std.ascii.isHex(c)) return false;
    }

    return true;
}

pub fn abbreviateSha(sha: []const u8, length: usize) []const u8 {
    return sha[0..@min(length, sha.len)];
}

pub fn truncateString(str: []const u8, max_len: usize) []const u8 {
    if (str.len <= max_len) return str;
    return str[0..max_len];
}

pub fn parseGitConfig(content: []const u8, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var config = std.StringHashMap([]const u8).init(allocator);
    errdefer config.deinit();

    var lines = std.mem.tokenizeAny(u8, content, "\n\r");
    var current_section: ?[]const u8 = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') {
            continue;
        }

        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            // Section header
            current_section = try allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
            continue;
        }

        // Key-value pair
        const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");

        const full_key = if (current_section) |section|
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ section, key })
        else
            try allocator.dupe(u8, key);

        try config.put(full_key, try allocator.dupe(u8, value));
    }

    return config;
}

pub fn parseAuthorLine(line: []const u8) struct {
    name: []const u8,
    email: []const u8,
    timestamp: i64,
    timezone: []const u8,
} {
    const name = extractName(line);
    const email = extractEmail(line) orelse "";

    // Find timestamp after '>'
    const email_end = std.mem.lastIndexOf(u8, line, ">") orelse line.len;
    const remainder = std.mem.trim(u8, line[email_end + 1 ..], " \t");

    var parts = std.mem.tokenizeAny(u8, remainder, " \t");
    const timestamp = if (parts.next()) |ts|
        std.fmt.parseInt(i64, ts, 10) catch 0
    else
        0;

    const timezone = parts.next() orelse "+0000";

    return .{
        .name = name,
        .email = email,
        .timestamp = timestamp,
        .timezone = timezone,
    };
}

test "parseSize" {
    try std.testing.expectEqual(@as(?u64, 1024), parseSize("1K"));
    try std.testing.expectEqual(@as(?u64, 1024), parseSize("1k"));
    try std.testing.expectEqual(@as(?u64, 1048576), parseSize("1M"));
    try std.testing.expectEqual(@as(?u64, 1073741824), parseSize("1G"));
    try std.testing.expectEqual(@as(?u64, 100), parseSize("100"));
}

test "parseHexColor" {
    try std.testing.expectEqual(@as(?u32, 0xFFFFFF), parseHexColor("#FFF"));
    try std.testing.expectEqual(@as(?u32, 0xFF0000), parseHexColor("#FF0000"));
    try std.testing.expectEqual(@as(?u32, 0x123456), parseHexColor("123456"));
}

test "extractEmail" {
    try std.testing.expectEqualStrings("user@example.com", extractEmail("John Doe <user@example.com>").?);
    try std.testing.expectEqual(@as(?[]const u8, null), extractEmail("John Doe"));
}

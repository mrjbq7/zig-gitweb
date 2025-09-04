const std = @import("std");
const gitweb = @import("../gitweb.zig");
const git = @import("../git.zig");
const html = @import("../html.zig");
const parsing = @import("../parsing.zig");
const shared = @import("shared.zig");

const c = git.c;

pub fn atom(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    // Set content type for Atom feed
    ctx.page.mimetype = "application/atom+xml";
    ctx.page.charset = "UTF-8";

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try writer.writeAll("<feed xmlns=\"http://www.w3.org/2005/Atom\">\n");

    // Feed title
    try writer.writeAll("  <title>");
    try html.htmlEscape(writer, repo.name);

    // Add branch/path info if present
    const ref_name = ctx.query.get("h");
    const path = ctx.query.get("path");

    if (path) |p| {
        try writer.writeAll("/");
        try html.htmlEscape(writer, p);
    }

    if (ref_name) |ref| {
        if (!std.mem.eql(u8, ref, "HEAD")) {
            try writer.writeAll(", branch ");
            try html.htmlEscape(writer, ref);
        }
    }

    try writer.writeAll("</title>\n");

    // Feed subtitle (repository description)
    if (repo.desc.len > 0) {
        try writer.writeAll("  <subtitle>");
        try html.htmlEscape(writer, repo.desc);
        try writer.writeAll("</subtitle>\n");
    }

    // Feed ID (unique identifier)
    const host = ctx.query.get("SERVER_NAME") orelse "localhost";
    const script_name = ctx.query.get("SCRIPT_NAME") orelse "/";
    try writer.print("  <id>http://{s}{s}?r={s}", .{ host, script_name, repo.name });
    if (ref_name) |ref| {
        try writer.print("&h={s}", .{ref});
    }
    try writer.writeAll("</id>\n");

    // Self link
    try writer.print("  <link rel='self' href='http://{s}{s}?r={s}&cmd=atom", .{ host, script_name, repo.name });
    if (ref_name) |ref| {
        try writer.print("&h={s}", .{ref});
    }
    try writer.writeAll("'/>\n");

    // Alternate link (HTML version)
    try writer.print("  <link rel='alternate' type='text/html' href='http://{s}{s}?r={s}", .{ host, script_name, repo.name });
    if (ref_name) |ref| {
        try writer.print("&h={s}", .{ref});
    }
    try writer.writeAll("'/>\n");

    // Open repository
    var git_repo = (try shared.openRepositoryWithError(ctx, writer)) orelse return;
    defer git_repo.close();

    // Set up revision walker
    var walk = try git_repo.revwalk();
    defer walk.free();

    // Get starting point
    if (ref_name) |ref| {
        // Try to resolve the reference
        if (shared.resolveReference(ctx, &git_repo, ref)) |reference| {
            defer @constCast(&reference).free();
            const oid = @constCast(&reference).target();
            if (oid) |o| {
                _ = c.git_revwalk_push(walk.walk, o);
            } else {
                try walk.pushHead();
            }
        } else |_| {
            try walk.pushHead();
        }
    } else {
        try walk.pushHead();
    }

    // Use natural order (faster than explicit time sorting)
    walk.setSorting(c.GIT_SORT_NONE);

    // Limit to path if specified
    if (path) |p| {
        // Note: libgit2 doesn't have built-in path filtering for revwalk
        // We'll have to check each commit manually
        _ = p;
    }

    // Track if this is the first commit (for feed updated time)
    var first_commit = true;
    const max_count: usize = 50; // Default to 50 entries
    var count: usize = 0;

    // Iterate through commits
    while (walk.next()) |oid| {
        if (count >= max_count) break;
        count += 1;

        var commit = git_repo.lookupCommit(&oid) catch continue;
        defer commit.free();

        // If this is the first commit, use its date for the feed's updated time
        if (first_commit) {
            try writer.writeAll("  <updated>");
            try writeIso8601Date(writer, commit.time());
            try writer.writeAll("</updated>\n");
            first_commit = false;
        }

        // Write the entry
        try writeAtomEntry(ctx, writer, &commit, host, script_name);
    }

    try writer.writeAll("</feed>\n");
}

fn writeAtomEntry(ctx: *gitweb.Context, writer: anytype, commit: *git.Commit, host: []const u8, script_name: []const u8) !void {
    const repo = ctx.repo.?;

    try writer.writeAll("  <entry>\n");

    // Entry title (commit subject)
    const message = commit.message();
    const parsed = parsing.parseCommitMessage(message);

    try writer.writeAll("    <title>");
    try html.htmlEscape(writer, parsed.subject);
    try writer.writeAll("</title>\n");

    // Entry ID (unique identifier)
    var oid_str: [40]u8 = undefined;
    _ = c.git_oid_fmt(&oid_str, commit.id());

    try writer.print("    <id>urn:sha1:{s}</id>\n", .{&oid_str});

    // Author information
    const author = commit.author();

    try writer.writeAll("    <author>\n");
    try writer.writeAll("      <name>");
    try html.htmlEscape(writer, std.mem.span(author.name));
    try writer.writeAll("</name>\n");

    const email = std.mem.span(author.email);
    if (email.len > 0) {
        try writer.writeAll("      <email>");
        try html.htmlEscape(writer, email);
        try writer.writeAll("</email>\n");
    }
    try writer.writeAll("    </author>\n");

    // Published date (author date)
    try writer.writeAll("    <published>");
    try writeIso8601Date(writer, commit.author().when.time);
    try writer.writeAll("</published>\n");

    // Updated date (committer date)
    try writer.writeAll("    <updated>");
    try writeIso8601Date(writer, commit.time());
    try writer.writeAll("</updated>\n");

    // Link to commit page
    try writer.print("    <link rel='alternate' type='text/html' href='http://{s}{s}?r={s}&cmd=commit&id={s}'/>\n", .{ host, script_name, repo.name, &oid_str });

    // Content (full commit message)
    try writer.writeAll("    <content type='text'>");
    try html.htmlEscape(writer, message);
    try writer.writeAll("</content>\n");

    try writer.writeAll("  </entry>\n");
}

fn writeIso8601Date(writer: anytype, timestamp: i64) !void {
    // Convert Unix timestamp to ISO 8601 format
    // Format: YYYY-MM-DDTHH:MM:SSZ

    const seconds_per_minute = 60;
    const seconds_per_hour = 3600;
    const seconds_per_day = 86400;

    // Days in each month (non-leap year)
    const days_in_month = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    const t = timestamp;

    // Calculate days since epoch
    const total_days = @divFloor(t, seconds_per_day);
    const time_of_day = @mod(t, seconds_per_day);

    // Calculate time components
    const hours: u32 = @intCast(@divFloor(time_of_day, seconds_per_hour));
    const minutes: u32 = @intCast(@divFloor(@mod(time_of_day, seconds_per_hour), seconds_per_minute));
    const seconds: u32 = @intCast(@mod(time_of_day, seconds_per_minute));

    // Calculate date from days since epoch
    // Start from 1970-01-01
    var year: u32 = 1970;
    var days_left: i64 = total_days;

    // Calculate year
    while (true) {
        const days_this_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (days_left < days_this_year) break;
        days_left -= days_this_year;
        year += 1;
    }

    // Calculate month and day
    var month: u32 = 1;
    var day: u32 = 1;

    for (days_in_month, 0..) |days, m| {
        var days_this_month = days;
        if (m == 1 and isLeapYear(year)) {
            days_this_month = 29; // February in leap year
        }

        if (days_left < days_this_month) {
            month = @intCast(m + 1);
            day = @intCast(days_left + 1);
            break;
        }
        days_left -= days_this_month;
    }

    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year, month, day, hours, minutes, seconds,
    });
}

fn isLeapYear(year: u32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    if (@mod(year, 4) == 0) return true;
    return false;
}

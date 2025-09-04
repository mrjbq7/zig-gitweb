const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const git = @import("../git.zig");
const shared = @import("shared.zig");

const c = git.c;

pub fn stats(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='stats'>\n");

    // Show which branch we're looking at
    const ref_name = ctx.query.get("h") orelse "HEAD";
    if (std.mem.eql(u8, ref_name, "HEAD")) {
        try writer.writeAll("<h2>Repository Statistics (All Time)</h2>\n");
    } else {
        try writer.print("<h2>Repository Statistics - Branch: {s}</h2>\n", .{ref_name});
    }

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Collect statistics
    var stats_data = try collectStatistics(ctx, &git_repo);
    defer stats_data.deinit(ctx.allocator);

    // Recent Activity Section
    try writer.writeAll("<div class='stats-section'>\n");
    try writer.writeAll("<h3>Recent Activity (Last 30 Days)</h3>\n");
    try renderRecentActivity(ctx, writer, &stats_data);
    try writer.writeAll("</div>\n");

    // Commits by Time Chart
    try writer.writeAll("<div class='stats-section'>\n");
    try writer.writeAll("<h3>Commits Over Time</h3>\n");
    try writer.writeAll("<canvas id='commits-by-time' width='800' height='400'></canvas>\n");
    try renderCommitsByTimeChart(writer, &stats_data);
    try writer.writeAll("</div>\n");

    // Commits by Author Chart
    try writer.writeAll("<div class='stats-section'>\n");
    try writer.writeAll("<h3>Top Contributors</h3>\n");
    try writer.writeAll("<canvas id='commits-by-author' width='800' height='400'></canvas>\n");
    try renderCommitsByAuthorChart(writer, &stats_data);
    try writer.writeAll("</div>\n");

    // Commits by Day of Week
    try writer.writeAll("<div class='stats-section'>\n");
    try writer.writeAll("<h3>Activity by Day of Week</h3>\n");
    try writer.writeAll("<canvas id='commits-by-dow' width='800' height='400'></canvas>\n");
    try renderCommitsByDayOfWeekChart(writer, &stats_data);
    try writer.writeAll("</div>\n");

    // Commits by Hour of Day
    try writer.writeAll("<div class='stats-section'>\n");
    try writer.writeAll("<h3>Activity by Hour of Day</h3>\n");
    try writer.writeAll("<canvas id='commits-by-hour' width='800' height='400'></canvas>\n");
    try renderCommitsByHourChart(writer, &stats_data);
    try writer.writeAll("</div>\n");

    try writer.writeAll("</div>\n");
}

const StatsData = struct {
    total_commits: usize,
    authors: std.StringHashMap(usize),
    commits_by_date: std.StringHashMap(usize),
    commits_by_dow: [7]usize,
    commits_by_hour: [24]usize,
    file_changes: std.StringHashMap(usize),
    recent_commits: std.ArrayList(CommitInfo),

    const CommitInfo = struct {
        oid: [40]u8,
        author: []const u8,
        timestamp: i64,
        message: []const u8,
    };

    fn init(allocator: std.mem.Allocator) StatsData {
        return .{
            .total_commits = 0,
            .authors = std.StringHashMap(usize).init(allocator),
            .commits_by_date = std.StringHashMap(usize).init(allocator),
            .commits_by_dow = [_]usize{0} ** 7,
            .commits_by_hour = [_]usize{0} ** 24,
            .file_changes = std.StringHashMap(usize).init(allocator),
            .recent_commits = std.ArrayList(CommitInfo).empty,
        };
    }

    fn deinit(self: *StatsData, allocator: std.mem.Allocator) void {
        // Free author keys
        var author_iter = self.authors.iterator();
        while (author_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.authors.deinit();

        // Free date keys
        var date_iter = self.commits_by_date.iterator();
        while (date_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.commits_by_date.deinit();

        self.file_changes.deinit();
        for (self.recent_commits.items) |commit| {
            allocator.free(commit.author);
            allocator.free(commit.message);
        }
        self.recent_commits.deinit(allocator);
    }
};

fn collectStatistics(ctx: *gitweb.Context, repo: *git.Repository) !StatsData {
    var stats_data = StatsData.init(ctx.allocator);
    errdefer stats_data.deinit(ctx.allocator);

    var walk = try repo.revwalk();
    defer walk.free();

    // Check for branch/ref filter
    const ref_name = ctx.query.get("h") orelse "HEAD";

    // Try to resolve the reference
    if (std.mem.eql(u8, ref_name, "HEAD")) {
        try walk.pushHead();
    } else {
        // Try to get the reference
        var ref = repo.getReference(ref_name) catch {
            // If direct reference fails, try with refs/heads/ prefix
            const full_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_name}, @as(u8, 0));
            defer ctx.allocator.free(full_ref);

            var ref2 = repo.getReference(full_ref) catch {
                // Fall back to HEAD if branch not found
                try walk.pushHead();
                walk.setSorting(c.GIT_SORT_TIME);
                return collectStatisticsFromWalk(ctx, repo, &walk, &stats_data);
            };
            defer ref2.free();

            const oid = ref2.target() orelse {
                // Fall back to HEAD if target not found
                try walk.pushHead();
                walk.setSorting(c.GIT_SORT_TIME);
                return collectStatisticsFromWalk(ctx, repo, &walk, &stats_data);
            };
            _ = c.git_revwalk_push(walk.walk, oid);
            walk.setSorting(c.GIT_SORT_TIME);
            return collectStatisticsFromWalk(ctx, repo, &walk, &stats_data);
        };
        defer ref.free();

        const oid = ref.target() orelse {
            // Fall back to HEAD if target not found
            try walk.pushHead();
            walk.setSorting(c.GIT_SORT_TIME);
            return collectStatisticsFromWalk(ctx, repo, &walk, &stats_data);
        };
        _ = c.git_revwalk_push(walk.walk, oid);
    }

    walk.setSorting(c.GIT_SORT_TIME);
    return collectStatisticsFromWalk(ctx, repo, &walk, &stats_data);
}

fn collectStatisticsFromWalk(ctx: *gitweb.Context, repo: *git.Repository, walk: *git.RevWalk, stats_data: *StatsData) !StatsData {
    const now = std.time.timestamp();
    const thirty_days_ago = now - (30 * 24 * 60 * 60);

    // Process all commits in the branch/repository
    while (walk.next()) |oid| {
        var commit = try repo.lookupCommit(&oid);
        defer commit.free();

        const author_sig = commit.author();
        const author_name = std.mem.span(author_sig.name);
        const timestamp = commit.time();
        const message = commit.message();

        stats_data.total_commits += 1;

        // Count by author
        const author_copy = try ctx.allocator.dupe(u8, author_name);
        const result = try stats_data.authors.getOrPut(author_copy);
        if (result.found_existing) {
            ctx.allocator.free(author_copy);
            result.value_ptr.* += 1;
        } else {
            result.value_ptr.* = 1;
        }

        // Track recent commits
        if (timestamp >= thirty_days_ago and stats_data.recent_commits.items.len < 100) {
            var commit_info = StatsData.CommitInfo{
                .oid = undefined,
                .author = try ctx.allocator.dupe(u8, author_name),
                .timestamp = timestamp,
                .message = try ctx.allocator.dupe(u8, message),
            };
            const oid_str = try git.oidToString(&oid);
            @memcpy(&commit_info.oid, oid_str[0..40]);
            try stats_data.recent_commits.append(ctx.allocator, commit_info);
        }

        // Count by day of week and hour
        const seconds_since_epoch = @as(u64, @intCast(timestamp));
        const day_of_week = @divTrunc(seconds_since_epoch / 86400 + 4, 1) % 7; // 0 = Sunday
        const hour_of_day = @divTrunc(@mod(seconds_since_epoch, 86400), 3600);

        stats_data.commits_by_dow[day_of_week] += 1;
        stats_data.commits_by_hour[hour_of_day] += 1;

        // Count by date (YYYY-MM)
        const year = @divTrunc(seconds_since_epoch, 31536000) + 1970;
        const month = @divTrunc(@mod(seconds_since_epoch, 31536000), 2629746) + 1; // Approximate
        const date_key = try std.fmt.allocPrint(ctx.allocator, "{d}-{d:0>2}", .{ year, month });

        const date_key_copy = try ctx.allocator.dupe(u8, date_key);
        ctx.allocator.free(date_key);

        const date_result = try stats_data.commits_by_date.getOrPut(date_key_copy);
        if (date_result.found_existing) {
            ctx.allocator.free(date_key_copy);
            date_result.value_ptr.* += 1;
        } else {
            date_result.value_ptr.* = 1;
        }
    }

    return stats_data.*;
}

fn renderRecentActivity(ctx: *gitweb.Context, writer: anytype, stats_data: *const StatsData) !void {
    try writer.writeAll("<div class='stats-summary'>\n");
    try writer.print("<p>Total Commits: <strong>{d}</strong></p>\n", .{stats_data.total_commits});
    try writer.print("<p>Total Contributors: <strong>{d}</strong></p>\n", .{stats_data.authors.count()});
    try writer.print("<p>Recent Commits (30 days): <strong>{d}</strong></p>\n", .{stats_data.recent_commits.items.len});
    try writer.writeAll("</div>\n");

    // Top 10 contributors
    try writer.writeAll("<h4>Top Contributors</h4>\n");
    try writer.writeAll("<table class='list'>\n");
    try writer.writeAll("<tr><th>Author</th><th>Commits</th></tr>\n");

    // Sort authors by commit count
    const AuthorEntry = struct { name: []const u8, count: usize };
    var author_list = std.ArrayList(AuthorEntry).empty;
    defer author_list.deinit(ctx.allocator);

    var iter = stats_data.authors.iterator();
    while (iter.next()) |entry| {
        try author_list.append(ctx.allocator, .{ .name = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    std.mem.sort(AuthorEntry, author_list.items, {}, struct {
        fn lessThan(_: void, a: AuthorEntry, b: AuthorEntry) bool {
            return a.count > b.count;
        }
    }.lessThan);

    const limit = @min(10, author_list.items.len);
    for (author_list.items[0..limit]) |author| {
        try writer.writeAll("<tr>");
        try writer.writeAll("<td>");
        try html.htmlEscape(writer, author.name);
        try writer.writeAll("</td>");
        try writer.print("<td>{d}</td>", .{author.count});
        try writer.writeAll("</tr>\n");
    }

    try writer.writeAll("</table>\n");
}

fn renderCommitsByTimeChart(writer: anytype, stats_data: *const StatsData) !void {
    // Sort dates chronologically
    const DateEntry = struct { date: []const u8, count: usize };
    const allocator = std.heap.page_allocator;
    var date_list = std.ArrayList(DateEntry).empty;
    defer date_list.deinit(allocator);

    var date_iter = stats_data.commits_by_date.iterator();
    while (date_iter.next()) |entry| {
        try date_list.append(allocator, .{ .date = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    std.mem.sort(DateEntry, date_list.items, {}, struct {
        fn lessThan(_: void, a: DateEntry, b: DateEntry) bool {
            return std.mem.order(u8, a.date, b.date) == .lt;
        }
    }.lessThan);

    try writer.writeAll("<script>\n");
    try writer.writeAll("new Chart(document.getElementById('commits-by-time'), {\n");
    try writer.writeAll("  type: 'line',\n");
    try writer.writeAll("  data: {\n");

    // Generate labels and data from sorted dates (show all data)
    try writer.writeAll("    labels: [");
    for (date_list.items, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("'{s}'", .{entry.date});
    }
    try writer.writeAll("],\n");

    try writer.writeAll("    datasets: [{\n");
    try writer.writeAll("      label: 'Commits',\n");
    try writer.writeAll("      data: [");

    for (date_list.items, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{d}", .{entry.count});
    }

    try writer.writeAll("],\n");
    try writer.writeAll("      borderColor: 'rgb(75, 192, 192)',\n");
    try writer.writeAll("      tension: 0.1\n");
    try writer.writeAll("    }]\n");
    try writer.writeAll("  },\n");
    try writer.writeAll("  options: {\n");
    try writer.writeAll("    responsive: false,\n");
    try writer.writeAll("    scales: {\n");
    try writer.writeAll("      y: { beginAtZero: true }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("});\n");
    try writer.writeAll("</script>\n");
}

fn renderCommitsByAuthorChart(writer: anytype, stats_data: *const StatsData) !void {
    // Sort authors by commit count
    const AuthorEntry = struct { name: []const u8, count: usize };
    const allocator = std.heap.page_allocator;
    var author_list = std.ArrayList(AuthorEntry).empty;
    defer author_list.deinit(allocator);

    var iter = stats_data.authors.iterator();
    while (iter.next()) |entry| {
        try author_list.append(allocator, .{ .name = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    std.mem.sort(AuthorEntry, author_list.items, {}, struct {
        fn lessThan(_: void, a: AuthorEntry, b: AuthorEntry) bool {
            return a.count > b.count;
        }
    }.lessThan);

    try writer.writeAll("<script>\n");
    try writer.writeAll("new Chart(document.getElementById('commits-by-author'), {\n");
    try writer.writeAll("  type: 'bar',\n");
    try writer.writeAll("  data: {\n");

    // Get top 10 authors
    try writer.writeAll("    labels: [");
    const limit = @min(10, author_list.items.len);
    for (author_list.items[0..limit], 0..) |author, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("'{s}'", .{author.name});
    }
    try writer.writeAll("],\n");

    try writer.writeAll("    datasets: [{\n");
    try writer.writeAll("      label: 'Commits',\n");
    try writer.writeAll("      data: [");

    for (author_list.items[0..limit], 0..) |author, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{d}", .{author.count});
    }

    try writer.writeAll("],\n");
    try writer.writeAll("      backgroundColor: 'rgba(54, 162, 235, 0.5)'\n");
    try writer.writeAll("    }]\n");
    try writer.writeAll("  },\n");
    try writer.writeAll("  options: {\n");
    try writer.writeAll("    responsive: false,\n");
    try writer.writeAll("    scales: {\n");
    try writer.writeAll("      y: { beginAtZero: true }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("});\n");
    try writer.writeAll("</script>\n");
}

fn renderCommitsByDayOfWeekChart(writer: anytype, stats_data: *const StatsData) !void {
    try writer.writeAll("<script>\n");
    try writer.writeAll("new Chart(document.getElementById('commits-by-dow'), {\n");
    try writer.writeAll("  type: 'bar',\n");
    try writer.writeAll("  data: {\n");
    try writer.writeAll("    labels: ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'],\n");
    try writer.writeAll("    datasets: [{\n");
    try writer.writeAll("      label: 'Commits',\n");
    try writer.writeAll("      data: [");

    for (stats_data.commits_by_dow, 0..) |commits, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{d}", .{commits});
    }

    try writer.writeAll("],\n");
    try writer.writeAll("      backgroundColor: 'rgba(255, 99, 132, 0.5)'\n");
    try writer.writeAll("    }]\n");
    try writer.writeAll("  },\n");
    try writer.writeAll("  options: {\n");
    try writer.writeAll("    responsive: false,\n");
    try writer.writeAll("    scales: {\n");
    try writer.writeAll("      y: { beginAtZero: true }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("});\n");
    try writer.writeAll("</script>\n");
}

fn renderCommitsByHourChart(writer: anytype, stats_data: *const StatsData) !void {
    try writer.writeAll("<script>\n");
    try writer.writeAll("new Chart(document.getElementById('commits-by-hour'), {\n");
    try writer.writeAll("  type: 'line',\n");
    try writer.writeAll("  data: {\n");
    try writer.writeAll("    labels: [");

    for (0..24) |hour| {
        if (hour > 0) try writer.writeAll(", ");
        try writer.print("'{d}:00'", .{hour});
    }

    try writer.writeAll("],\n");
    try writer.writeAll("    datasets: [{\n");
    try writer.writeAll("      label: 'Commits',\n");
    try writer.writeAll("      data: [");

    for (stats_data.commits_by_hour, 0..) |commits, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{d}", .{commits});
    }

    try writer.writeAll("],\n");
    try writer.writeAll("      borderColor: 'rgb(153, 102, 255)',\n");
    try writer.writeAll("      tension: 0.1\n");
    try writer.writeAll("    }]\n");
    try writer.writeAll("  },\n");
    try writer.writeAll("  options: {\n");
    try writer.writeAll("    responsive: false,\n");
    try writer.writeAll("    scales: {\n");
    try writer.writeAll("      y: { beginAtZero: true }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("});\n");
    try writer.writeAll("</script>\n");
}

fn renderMostActiveFiles(ctx: *gitweb.Context, writer: anytype, stats_data: *const StatsData) !void {
    _ = ctx;
    _ = stats_data;
    try writer.writeAll("<p>File activity tracking coming soon...</p>\n");
}

const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn stats(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='stats'>\n");
    try writer.writeAll("<h2>Repository Statistics</h2>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Collect statistics
    var stats_data = try collectStats(ctx, &git_repo);

    // Display overview
    try writer.writeAll("<div class='stats-overview'>\n");
    try writer.writeAll("<h3>Overview</h3>\n");
    try writer.writeAll("<table class='stats-table'>\n");

    // Total commits
    try writer.print("<tr><th>Total Commits:</th><td>{d}</td></tr>\n", .{stats_data.total_commits});

    // Total authors
    try writer.print("<tr><th>Total Authors:</th><td>{d}</td></tr>\n", .{stats_data.authors.count()});

    // Date range
    try writer.writeAll("<tr><th>First Commit:</th><td>");
    if (stats_data.first_commit_time > 0) {
        try parsing.formatTimestamp(stats_data.first_commit_time, writer);
    } else {
        try writer.writeAll("-");
    }
    try writer.writeAll("</td></tr>\n");

    try writer.writeAll("<tr><th>Latest Commit:</th><td>");
    if (stats_data.last_commit_time > 0) {
        try parsing.formatTimestamp(stats_data.last_commit_time, writer);
    } else {
        try writer.writeAll("-");
    }
    try writer.writeAll("</td></tr>\n");

    // File statistics
    try writer.print("<tr><th>Total Files:</th><td>{d}</td></tr>\n", .{stats_data.total_files});
    try writer.print("<tr><th>Total Size:</th><td>", .{});
    try parsing.formatFileSize(stats_data.total_size, writer);
    try writer.writeAll("</td></tr>\n");

    try writer.writeAll("</table>\n");
    try writer.writeAll("</div>\n");

    // Top authors by commits
    try writer.writeAll("<div class='stats-authors'>\n");
    try writer.writeAll("<h3>Top Authors (by commits)</h3>\n");

    const headers = [_][]const u8{ "Author", "Commits", "Percentage", "First", "Last" };
    try html.writeTableHeader(writer, &headers);

    // Sort authors by commit count
    var author_entries = try ctx.allocator.alloc(AuthorStat, stats_data.authors.count());
    defer ctx.allocator.free(author_entries);

    var iter = stats_data.authors.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| {
        author_entries[i] = entry.value_ptr.*;
        i += 1;
    }

    std.sort.pdq(AuthorStat, author_entries, {}, struct {
        fn lessThan(_: void, a: AuthorStat, b: AuthorStat) bool {
            return a.commit_count > b.commit_count;
        }
    }.lessThan);

    // Display top 10 authors
    const max_authors = @min(10, author_entries.len);
    for (0..max_authors) |idx| {
        const author = author_entries[idx];
        const percentage = (@as(f64, @floatFromInt(author.commit_count)) / @as(f64, @floatFromInt(stats_data.total_commits))) * 100.0;

        try html.writeTableRow(writer, if (idx % 2 == 0) "even" else null);

        try writer.writeAll("<td>");
        try html.htmlEscape(writer, author.name);
        try writer.writeAll("</td>");

        try writer.print("<td>{d}</td>", .{author.commit_count});

        try writer.print("<td>{d:.1}%</td>", .{percentage});

        try writer.writeAll("<td>");
        try shared.formatAge(writer, author.first_commit);
        try writer.writeAll("</td>");

        try writer.writeAll("<td>");
        try shared.formatAge(writer, author.last_commit);
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
    }

    try html.writeTableFooter(writer);
    try writer.writeAll("</div>\n");

    // Activity over time (weekly commits)
    try writer.writeAll("<div class='stats-activity'>\n");
    try writer.writeAll("<h3>Activity (last 52 weeks)</h3>\n");

    // Calculate weekly activity
    const now = std.time.timestamp();
    const week_seconds = 7 * 24 * 60 * 60;
    const weeks_ago_52 = now - (52 * week_seconds);

    var weekly_commits = try ctx.allocator.alloc(u32, 52);
    defer ctx.allocator.free(weekly_commits);
    @memset(weekly_commits, 0);

    // Count commits per week
    for (stats_data.commit_times.items) |commit_time| {
        if (commit_time >= weeks_ago_52) {
            const weeks_from_start = @divFloor(commit_time - weeks_ago_52, week_seconds);
            if (weeks_from_start < 52) {
                weekly_commits[@intCast(weeks_from_start)] += 1;
            }
        }
    }

    // Find max for scaling
    var max_weekly: u32 = 0;
    for (weekly_commits) |count| {
        if (count > max_weekly) max_weekly = count;
    }

    // Display activity graph
    try writer.writeAll("<div class='activity-graph'>\n");
    for (weekly_commits) |count| {
        const height = if (max_weekly > 0)
            @divFloor(count * 100, max_weekly)
        else
            0;

        try writer.print("<div class='activity-bar' style='height: {d}px' title='{d} commits'></div>", .{ height, count });
    }
    try writer.writeAll("</div>\n");

    // Add CSS for activity graph
    try writer.writeAll(
        \\<style>
        \\.activity-graph {
        \\    display: flex;
        \\    align-items: flex-end;
        \\    height: 100px;
        \\    border-bottom: 1px solid #ccc;
        \\    margin: 20px 0;
        \\}
        \\.activity-bar {
        \\    flex: 1;
        \\    background: #4CAF50;
        \\    margin: 0 1px;
        \\    min-height: 1px;
        \\}
        \\.stats-table { width: auto; }
        \\.stats-table th { text-align: left; padding-right: 20px; }
        \\</style>
        \\
    );

    try writer.writeAll("</div>\n");

    // Cleanup
    iter = stats_data.authors.iterator();
    while (iter.next()) |entry| {
        ctx.allocator.free(entry.value_ptr.name);
    }
    stats_data.authors.deinit();
    stats_data.commit_times.deinit(ctx.allocator);

    try writer.writeAll("</div>\n");
}

const AuthorStat = struct {
    name: []const u8,
    email: []const u8,
    commit_count: u32,
    first_commit: i64,
    last_commit: i64,
};

const StatsData = struct {
    total_commits: u32,
    authors: std.StringHashMap(AuthorStat),
    first_commit_time: i64,
    last_commit_time: i64,
    total_files: u32,
    total_size: u64,
    commit_times: std.ArrayList(i64),
};

fn collectStats(ctx: *gitweb.Context, repo: *git.Repository) !StatsData {
    var stats_data = StatsData{
        .total_commits = 0,
        .authors = std.StringHashMap(AuthorStat).init(ctx.allocator),
        .first_commit_time = std.math.maxInt(i64),
        .last_commit_time = 0,
        .total_files = 0,
        .total_size = 0,
        .commit_times = .empty,
    };

    // Walk all commits
    var walk = try repo.revwalk();
    defer walk.free();

    try walk.pushHead();
    walk.setSorting(c.GIT_SORT_TIME);

    while (walk.next()) |oid| {
        var commit = repo.lookupCommit(&oid) catch continue;
        defer commit.free();

        stats_data.total_commits += 1;

        // Get commit time
        const commit_time = commit.time();
        try stats_data.commit_times.append(ctx.allocator, commit_time);

        if (commit_time < stats_data.first_commit_time) {
            stats_data.first_commit_time = commit_time;
        }
        if (commit_time > stats_data.last_commit_time) {
            stats_data.last_commit_time = commit_time;
        }

        // Track author
        const author = commit.author();
        const author_name = std.mem.span(author.name);
        const author_email = if (author.email) |e| std.mem.span(e) else "";

        const author_key = try std.fmt.allocPrint(ctx.allocator, "{s} <{s}>", .{ author_name, author_email });
        defer ctx.allocator.free(author_key);

        const result = try stats_data.authors.getOrPut(author_key);
        if (!result.found_existing) {
            result.value_ptr.* = AuthorStat{
                .name = try ctx.allocator.dupe(u8, author_name),
                .email = author_email,
                .commit_count = 0,
                .first_commit = commit_time,
                .last_commit = commit_time,
            };
        }

        result.value_ptr.commit_count += 1;
        if (commit_time < result.value_ptr.first_commit) {
            result.value_ptr.first_commit = commit_time;
        }
        if (commit_time > result.value_ptr.last_commit) {
            result.value_ptr.last_commit = commit_time;
        }
    }

    // Get HEAD tree for file statistics
    var head_ref = repo.getHead() catch {
        return stats_data;
    };
    defer head_ref.free();

    const head_oid = head_ref.target() orelse return stats_data;
    var head_commit = repo.lookupCommit(head_oid) catch return stats_data;
    defer head_commit.free();

    var tree = head_commit.tree() catch return stats_data;
    defer tree.free();

    // Count files recursively
    try countTreeFiles(repo, &tree, &stats_data.total_files, &stats_data.total_size);

    return stats_data;
}

fn countTreeFiles(repo: *git.Repository, tree: *git.Tree, file_count: *u32, total_size: *u64) !void {
    const count = tree.entryCount();

    for (0..count) |i| {
        const entry = tree.entryByIndex(i).?;
        const entry_type = c.git_tree_entry_type(@ptrCast(entry));

        if (entry_type == c.GIT_OBJECT_BLOB) {
            file_count.* += 1;

            // Get blob size
            const blob_oid = c.git_tree_entry_id(@ptrCast(entry));
            var blob = repo.lookupBlob(@constCast(blob_oid)) catch continue;
            defer blob.free();

            total_size.* += @intCast(blob.size());
        } else if (entry_type == c.GIT_OBJECT_TREE) {
            // Recursively count in subdirectory
            const tree_oid = c.git_tree_entry_id(@ptrCast(entry));
            var subtree = repo.lookupTree(@constCast(tree_oid)) catch continue;
            defer subtree.free();

            try countTreeFiles(repo, &subtree, file_count, total_size);
        }
    }
}

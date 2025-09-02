const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = git.c;

pub fn commit(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    const commit_id = ctx.query.get("id") orelse return error.NoCommitId;

    try writer.writeAll("<div class='commit'>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Parse commit ID
    const oid = try git.stringToOid(commit_id);

    // Get the commit
    var commit_obj = try git_repo.lookupCommit(&oid);
    defer commit_obj.free();

    const oid_str = try git.oidToString(commit_obj.id());

    try writer.print("<h2>Commit {s}</h2>\n", .{oid_str[0..7]});

    // Commit info table
    try writer.writeAll("<table class='commit-info'>\n");

    // Author
    const author = commit_obj.author();
    try writer.writeAll("<tr><th>Author</th><td>");
    try html.htmlEscape(writer, std.mem.span(author.name));
    if (author.email) |email| {
        try writer.writeAll(" &lt;");
        try html.htmlEscape(writer, std.mem.span(email));
        try writer.writeAll("&gt;");
    }
    try writer.writeAll("</td></tr>\n");

    // Author date
    try writer.writeAll("<tr><th>Author Date</th><td>");
    try parsing.formatTimestamp(author.when.time, writer);
    const tz_buf = formatTimezone(author.when.offset);
    try writer.print(" {s}", .{tz_buf[0..5]}); // Only use first 5 chars (+HHMM)
    try writer.writeAll("</td></tr>\n");

    // Committer
    const committer = commit_obj.committer();
    const author_email = if (author.email) |e| std.mem.span(e) else "";
    const committer_email = if (committer.email) |e| std.mem.span(e) else "";
    if (!std.mem.eql(u8, std.mem.span(author.name), std.mem.span(committer.name)) or
        !std.mem.eql(u8, author_email, committer_email))
    {
        try writer.writeAll("<tr><th>Committer</th><td>");
        try html.htmlEscape(writer, std.mem.span(committer.name));
        if (committer.email) |email| {
            try writer.writeAll(" &lt;");
            try html.htmlEscape(writer, std.mem.span(email));
            try writer.writeAll("&gt;");
        }
        try writer.writeAll("</td></tr>\n");

        try writer.writeAll("<tr><th>Commit Date</th><td>");
        try parsing.formatTimestamp(committer.when.time, writer);
        const tz_buf2 = formatTimezone(committer.when.offset);
        try writer.print(" {s}", .{tz_buf2[0..5]}); // Only use first 5 chars (+HHMM)
        try writer.writeAll("</td></tr>\n");
    }

    // Parent commits
    const parent_count = commit_obj.parentCount();
    for (0..parent_count) |i| {
        var parent = try commit_obj.parent(@intCast(i));
        defer parent.free();

        const parent_oid_str = try git.oidToString(parent.id());

        try writer.writeAll("<tr><th>");
        if (i == 0) {
            try writer.writeAll("Parent");
        } else {
            try writer.print("Parent {d}", .{i + 1});
        }
        try writer.writeAll("</th><td>");
        try shared.writeCommitLink(ctx, writer, &parent_oid_str, parent_oid_str[0..7]);

        // Show parent's summary
        const parent_summary = parent.summary();
        if (parent_summary.len > 0) {
            try writer.writeAll(" (");
            try html.htmlEscape(writer, parent_summary);
            try writer.writeAll(")");
        }
        try writer.writeAll("</td></tr>\n");
    }

    // Tree
    var tree = try commit_obj.tree();
    defer tree.free();
    const tree_oid_str = try git.oidToString(tree.id());

    try writer.writeAll("<tr><th>Tree</th><td>");
    // Pass the commit ID, not the tree ID, since tree view expects a commit
    try shared.writeTreeLink(ctx, writer, &oid_str, null, tree_oid_str[0..7]);
    try writer.writeAll("</td></tr>\n");

    try writer.writeAll("</table>\n");

    // Commit message
    try writer.writeAll("<div class='commit-message'>\n");
    const message = commit_obj.message();
    const parsed_msg = parsing.parseCommitMessage(message);

    try writer.writeAll("<h3>");
    try html.htmlEscape(writer, parsed_msg.subject);
    try writer.writeAll("</h3>\n");

    if (parsed_msg.body.len > 0) {
        try writer.writeAll("<pre>");
        try html.htmlEscape(writer, parsed_msg.body);
        try writer.writeAll("</pre>\n");
    }
    try writer.writeAll("</div>\n");

    // Show diff
    try showCommitDiff(ctx, &git_repo, &commit_obj, writer);

    try writer.writeAll("</div>\n");
}

fn showCommitDiff(ctx: *gitweb.Context, repo: *git.Repository, commit_obj: *git.Commit, writer: anytype) !void {
    _ = ctx;

    try writer.writeAll("<h3>Changes</h3>\n");

    // Get parent tree (or null for initial commit)
    var parent_tree: ?git.Tree = null;
    if (commit_obj.parentCount() > 0) {
        var parent = try commit_obj.parent(0);
        defer parent.free();
        parent_tree = try parent.tree();
    }
    defer if (parent_tree) |*pt| pt.free();

    // Get commit tree
    var commit_tree = try commit_obj.tree();
    defer commit_tree.free();

    // Create diff
    var diff = try git.Diff.treeToTree(repo.repo, if (parent_tree) |pt| pt.tree else null, commit_tree.tree, null);
    defer diff.free();

    // Get statistics
    var stats = try diff.getStats();
    defer stats.free();

    const files_changed = stats.filesChanged();
    const insertions = stats.insertions();
    const deletions = stats.deletions();

    try writer.writeAll("<div class='diffstat'>\n");
    try writer.print("{d} file{s} changed, ", .{ files_changed, if (files_changed == 1) "" else "s" });
    try writer.print("<span style='color: green'>{d} insertion{s}(+)</span>, ", .{ insertions, if (insertions == 1) "" else "s" });
    try writer.print("<span style='color: red'>{d} deletion{s}(-)</span>\n", .{ deletions, if (deletions == 1) "" else "s" });
    try writer.writeAll("</div>\n");

    // Show file list
    try writer.writeAll("<div class='diff-files'>\n");
    const num_deltas = diff.numDeltas();

    for (0..num_deltas) |i| {
        const delta = diff.getDelta(i).?;
        const old_file = delta.*.old_file;
        const new_file = delta.*.new_file;

        try writer.writeAll("<div class='diff-file'>\n");

        // File header
        try writer.writeAll("<div class='diff-file-header'>");

        switch (delta.*.status) {
            c.GIT_DELTA_ADDED => {
                try writer.writeAll("<span style='color: green'>+++ ");
                try html.htmlEscape(writer, std.mem.span(new_file.path));
                try writer.writeAll("</span>");
            },
            c.GIT_DELTA_DELETED => {
                try writer.writeAll("<span style='color: red'>--- ");
                try html.htmlEscape(writer, std.mem.span(old_file.path));
                try writer.writeAll("</span>");
            },
            c.GIT_DELTA_MODIFIED => {
                try html.htmlEscape(writer, std.mem.span(new_file.path));
            },
            c.GIT_DELTA_RENAMED => {
                try html.htmlEscape(writer, std.mem.span(old_file.path));
                try writer.writeAll(" → ");
                try html.htmlEscape(writer, std.mem.span(new_file.path));
            },
            c.GIT_DELTA_COPIED => {
                try html.htmlEscape(writer, std.mem.span(old_file.path));
                try writer.writeAll(" → ");
                try html.htmlEscape(writer, std.mem.span(new_file.path));
                try writer.writeAll(" (copy)");
            },
            else => {
                try html.htmlEscape(writer, std.mem.span(new_file.path));
            },
        }

        try writer.writeAll("</div>\n");
        try writer.writeAll("</div>\n");
    }
    try writer.writeAll("</div>\n");

    // Show full diff
    try writer.writeAll("<pre class='diff'>\n");

    const callback_data = struct {
        writer: @TypeOf(writer),

        fn printLine(
            delta: [*c]const c.git_diff_delta,
            hunk: [*c]const c.git_diff_hunk,
            line: [*c]const c.git_diff_line,
            payload: ?*anyopaque,
        ) callconv(.c) c_int {
            _ = delta;
            _ = hunk;

            const self = @as(*@This(), @ptrCast(@alignCast(payload.?)));

            // Write line with appropriate styling
            switch (line.*.origin) {
                '+' => self.writer.writeAll("<span class='add'>+") catch return -1,
                '-' => self.writer.writeAll("<span class='del'>-") catch return -1,
                '@' => self.writer.writeAll("<span class='hunk'>@") catch return -1,
                'F' => {}, // File header lines - don't print the 'F'
                ' ' => self.writer.writeByte(' ') catch return -1, // Context line
                else => {}, // Don't print other origin characters
            }

            const content = @as([*]const u8, @ptrCast(line.*.content))[0..@intCast(line.*.content_len)];
            html.htmlEscape(self.writer, content) catch return -1;

            switch (line.*.origin) {
                '+', '-', '@' => self.writer.writeAll("</span>") catch return -1,
                else => {},
            }

            if (!std.mem.endsWith(u8, content, "\n")) {
                self.writer.writeAll("\n") catch return -1;
            }

            return 0;
        }
    }{ .writer = writer };

    try diff.print(c.GIT_DIFF_FORMAT_PATCH, @TypeOf(callback_data).printLine, @ptrCast(@constCast(&callback_data)));

    try writer.writeAll("</pre>\n");
}

fn formatTimezone(offset: c_int) [6]u8 {
    const abs_offset = @abs(offset);
    const hours = @divFloor(abs_offset, 60);
    const minutes = @mod(abs_offset, 60);
    var buf: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{s}{d:0>2}{d:0>2}", .{
        if (offset >= 0) "+" else "-",
        hours,
        minutes,
    }) catch unreachable;
    return buf;
}

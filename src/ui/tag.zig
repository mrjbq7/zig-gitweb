const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = git.c;

pub fn tag(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='tag'>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Get the tag name from query
    const tag_name = ctx.query.get("h") orelse ctx.query.get("id") orelse {
        try writer.writeAll("<p>No tag specified.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };

    // Look up the tag reference
    const ref_name = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/tags/{s}", .{tag_name}, 0);
    defer ctx.allocator.free(ref_name);

    var ref: ?*c.git_reference = null;
    if (c.git_reference_lookup(&ref, @ptrCast(git_repo.repo), ref_name) != 0) {
        try writer.writeAll("<p>Tag not found.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    }
    defer c.git_reference_free(ref);

    const oid = c.git_reference_target(ref);
    if (oid == null) {
        try writer.writeAll("<p>Invalid tag reference.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    }

    // Check if it's an annotated tag
    var tag_obj: ?*c.git_tag = null;
    const is_annotated = c.git_tag_lookup(&tag_obj, @ptrCast(git_repo.repo), oid) == 0;
    defer if (tag_obj != null) c.git_object_free(@ptrCast(tag_obj));

    if (is_annotated and tag_obj != null) {
        // Annotated tag - show tag information
        try writer.print("<h2>Tag {s}</h2>\n", .{tag_name});

        try writer.writeAll("<table class='tag-info'>\n");

        // Tag object ID
        const tag_oid_str = try git.oidToString(oid);
        try writer.writeAll("<tr><th>Tag ID</th><td>");
        try writer.print("{s}", .{tag_oid_str});
        try writer.writeAll("</td></tr>\n");

        // Target commit
        const target_oid = c.git_tag_target_id(tag_obj);
        const target_oid_str = try git.oidToString(target_oid);
        try writer.writeAll("<tr><th>Tagged Commit</th><td>");
        try shared.writeCommitLink(ctx, writer, &target_oid_str, target_oid_str[0..7]);

        // Get commit summary
        var commit = try git_repo.lookupCommit(target_oid);
        defer commit.free();
        const summary = commit.summary();
        if (summary.len > 0) {
            try writer.writeAll(" (");
            try html.htmlEscape(writer, summary);
            try writer.writeAll(")");
        }
        try writer.writeAll("</td></tr>\n");

        // Tagger
        const tagger = c.git_tag_tagger(tag_obj);
        if (tagger != null) {
            try writer.writeAll("<tr><th>Tagger</th><td>");
            try html.htmlEscape(writer, std.mem.span(tagger.*.name));
            if (tagger.*.email) |email| {
                try writer.writeAll(" &lt;");
                try html.htmlEscape(writer, std.mem.span(email));
                try writer.writeAll("&gt;");
            }
            try writer.writeAll("</td></tr>\n");

            // Tag date
            try writer.writeAll("<tr><th>Tag Date</th><td>");
            try parsing.formatTimestamp(tagger.*.when.time, writer);
            const tz_buf = formatTimezone(tagger.*.when.offset);
            try writer.print(" {s}", .{tz_buf[0..5]});
            try writer.writeAll("</td></tr>\n");
        }

        // Download links
        try writer.writeAll("<tr><th>Download</th><td>");
        if (ctx.repo) |r| {
            try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> | ", .{ r.name, tag_name });
            try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{ r.name, tag_name });
        } else {
            try writer.print("<a href='?cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> | ", .{tag_name});
            try writer.print("<a href='?cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{tag_name});
        }
        try writer.writeAll("</td></tr>\n");

        try writer.writeAll("</table>\n");

        // Tag message
        const message = c.git_tag_message(tag_obj);
        if (message != null and std.mem.span(message).len > 0) {
            try writer.writeAll("<div class='tag-message'>\n");
            try writer.writeAll("<h3>Tag Message</h3>\n");
            try writer.writeAll("<pre>");
            try html.htmlEscape(writer, std.mem.span(message));
            try writer.writeAll("</pre>\n");
            try writer.writeAll("</div>\n");
        }

        // Show the tagged commit details
        try writer.writeAll("<h3>Tagged Commit</h3>\n");
        try showCommitInfo(ctx, &git_repo, &commit, writer);
    } else {
        // Lightweight tag - just show the commit it points to
        try writer.print("<h2>Tag {s} (lightweight)</h2>\n", .{tag_name});

        try writer.writeAll("<table class='tag-info'>\n");

        // Target commit
        const commit_oid_str = try git.oidToString(oid);
        try writer.writeAll("<tr><th>Points to</th><td>");
        try shared.writeCommitLink(ctx, writer, &commit_oid_str, commit_oid_str[0..7]);

        // Get commit summary
        var commit = try git_repo.lookupCommit(oid);
        defer commit.free();
        const summary = commit.summary();
        if (summary.len > 0) {
            try writer.writeAll(" (");
            try html.htmlEscape(writer, summary);
            try writer.writeAll(")");
        }
        try writer.writeAll("</td></tr>\n");

        // Download links
        try writer.writeAll("<tr><th>Download</th><td>");
        if (ctx.repo) |r| {
            try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> | ", .{ r.name, tag_name });
            try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{ r.name, tag_name });
        } else {
            try writer.print("<a href='?cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> | ", .{tag_name});
            try writer.print("<a href='?cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{tag_name});
        }
        try writer.writeAll("</td></tr>\n");

        try writer.writeAll("</table>\n");

        // Show the commit details
        try writer.writeAll("<h3>Commit Details</h3>\n");
        try showCommitInfo(ctx, &git_repo, &commit, writer);
    }

    try writer.writeAll("</div>\n");
}

fn showCommitInfo(ctx: *gitweb.Context, repo: *git.Repository, commit: *git.Commit, writer: anytype) !void {
    _ = repo;
    const oid_str = try git.oidToString(commit.id());

    try writer.writeAll("<table class='commit-info'>\n");

    // Commit ID
    try writer.writeAll("<tr><th>Commit</th><td>");
    try shared.writeCommitLink(ctx, writer, &oid_str, &oid_str);
    try writer.writeAll("</td></tr>\n");

    // Author
    const author = commit.author();
    try writer.writeAll("<tr><th>Author</th><td>");
    try html.htmlEscape(writer, std.mem.span(author.name));
    if (author.email) |email| {
        try writer.writeAll(" &lt;");
        try html.htmlEscape(writer, std.mem.span(email));
        try writer.writeAll("&gt;");
    }
    try writer.writeAll("</td></tr>\n");

    // Author date
    try writer.writeAll("<tr><th>Date</th><td>");
    try parsing.formatTimestamp(author.when.time, writer);
    const tz_buf = formatTimezone(author.when.offset);
    try writer.print(" {s}", .{tz_buf[0..5]});
    try writer.writeAll("</td></tr>\n");

    // Parent commits
    const parent_count = commit.parentCount();
    for (0..parent_count) |i| {
        var parent = try commit.parent(@intCast(i));
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
    var tree = try commit.tree();
    defer tree.free();
    const tree_oid_str = try git.oidToString(tree.id());

    try writer.writeAll("<tr><th>Tree</th><td>");
    try shared.writeTreeLink(ctx, writer, &oid_str, null, tree_oid_str[0..7]);
    try writer.writeAll("</td></tr>\n");

    try writer.writeAll("</table>\n");

    // Commit message
    try writer.writeAll("<div class='commit-message'>\n");
    const message = commit.message();
    const parsed_msg = parsing.parseCommitMessage(message);

    try writer.writeAll("<h4>");
    try html.htmlEscape(writer, parsed_msg.subject);
    try writer.writeAll("</h4>\n");

    if (parsed_msg.body.len > 0) {
        try writer.writeAll("<pre>");
        try html.htmlEscape(writer, parsed_msg.body);
        try writer.writeAll("</pre>\n");
    }
    try writer.writeAll("</div>\n");
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

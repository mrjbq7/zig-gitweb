const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

pub fn summary(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='summary'>\n");
    try writer.print("<h2>{s}</h2>\n", .{repo.name});

    if (repo.desc.len > 0) {
        try writer.writeAll("<div class='desc'>");
        try html.htmlEscape(writer, repo.desc);
        try writer.writeAll("</div>\n");
    }

    if (repo.homepage) |homepage| {
        try writer.writeAll("<div class='homepage'>Homepage: ");
        try html.writeLink(writer, homepage, homepage);
        try writer.writeAll("</div>\n");
    }

    if (repo.owner) |owner| {
        try writer.writeAll("<div class='owner'>Owner: ");
        try html.htmlEscape(writer, owner);
        try writer.writeAll("</div>\n");
    }

    if (repo.clone_url) |clone_url| {
        try writer.writeAll("<div class='clone-url'>Clone URL: <code>");
        try html.htmlEscape(writer, clone_url);
        try writer.writeAll("</code></div>\n");
    }

    // Show recent commits
    try showRecentCommits(ctx, repo, writer);

    // Show branches
    try showBranches(ctx, repo, writer);

    // Show tags
    try showTags(ctx, repo, writer);

    try writer.writeAll("</div>\n");
}

fn showRecentCommits(ctx: *gitweb.Context, repo: *gitweb.Repo, writer: anytype) !void {
    try writer.writeAll("<h3>Recent Commits</h3>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        return;
    };
    defer git_repo.close();

    var walk = try git_repo.revwalk();
    defer walk.free();

    // Get the branch from query parameter or use HEAD
    const ref_name = ctx.query.get("h") orelse "HEAD";
    if (std.mem.eql(u8, ref_name, "HEAD")) {
        try walk.pushHead();
    } else {
        // Push the specific branch reference
        const full_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_name}, @as(u8, 0));
        defer ctx.allocator.free(full_ref);
        walk.pushRef(full_ref) catch {
            // If the full ref doesn't work, try the name as-is (might be a tag or full ref already)
            walk.pushRef(ref_name) catch {
                // Fall back to HEAD if the reference doesn't exist
                try walk.pushHead();
            };
        };
    }
    walk.setSorting(@import("../git.zig").c.GIT_SORT_TIME);

    try html.writeTableHeader(writer, &[_][]const u8{ "Age", "Commit", "Author", "Message" });

    var count: u32 = 0;
    while (walk.next()) |oid| {
        if (count >= ctx.cfg.summary_log) break;
        count += 1;

        var commit = try git_repo.lookupCommit(&oid);
        defer commit.free();

        const oid_str = try git.oidToString(commit.id());
        const author_sig = commit.author();
        const commit_time = commit.time();

        try html.writeTableRow(writer, null);

        // Age
        try writer.writeAll("<td class='age' data-timestamp='");
        try writer.print("{d}", .{commit_time});
        try writer.writeAll("'>");
        try shared.formatAge(writer, commit_time);
        try writer.writeAll("</td>");

        // Commit hash
        try writer.writeAll("<td class='commit-hash'>");
        try shared.writeCommitLink(ctx, writer, &oid_str, oid_str[0..7]);
        try writer.writeAll("</td>");

        // Author
        try writer.writeAll("<td>");
        try html.htmlEscape(writer, std.mem.span(author_sig.name));
        try writer.writeAll("</td>");

        // Message
        try writer.writeAll("<td>");
        const commit_summary = commit.summary();
        const truncated = parsing.truncateString(commit_summary, @intCast(ctx.cfg.max_msg_len));
        try html.htmlEscape(writer, truncated);
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
    }

    try html.writeTableFooter(writer);
}

fn showBranches(ctx: *gitweb.Context, repo: *gitweb.Repo, writer: anytype) !void {
    try writer.writeAll("<h3>Branches</h3>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        return;
    };
    defer git_repo.close();

    const branches = try git_repo.getBranches(ctx.allocator);
    defer ctx.allocator.free(branches);

    if (branches.len == 0) {
        try writer.writeAll("<p>No branches found.</p>\n");
        return;
    }

    try html.writeTableHeader(writer, &[_][]const u8{ "Branch", "Commit", "Author", "Age" });

    var shown: u32 = 0;
    for (branches) |branch| {
        if (!branch.is_remote and shown < ctx.cfg.summary_branches) {
            shown += 1;
            defer @constCast(&branch.ref).free();

            const target = @constCast(&branch.ref).target() orelse continue;
            var commit = try git_repo.lookupCommit(target);
            defer commit.free();

            const oid_str = try git.oidToString(commit.id());
            const author_sig = commit.author();
            const commit_time = commit.time();

            try html.writeTableRow(writer, null);

            // Branch name
            try writer.writeAll("<td>");
            if (ctx.repo) |r| {
                try writer.print("<a href='?r={s}&h={s}'>{s}</a>", .{ r.name, branch.name, branch.name });
            } else {
                try writer.print("<a href='?h={s}'>{s}</a>", .{ branch.name, branch.name });
            }
            try writer.writeAll("</td>");

            // Commit
            try writer.writeAll("<td>");
            try shared.writeCommitLink(ctx, writer, &oid_str, oid_str[0..7]);
            try writer.writeAll("</td>");

            // Author
            try writer.writeAll("<td>");
            try html.htmlEscape(writer, std.mem.span(author_sig.name));
            try writer.writeAll("</td>");

            // Age
            try writer.writeAll("<td class='age' data-timestamp='");
            try writer.print("{d}", .{commit_time});
            try writer.writeAll("'>");
            try shared.formatAge(writer, commit_time);
            try writer.writeAll("</td>");

            try writer.writeAll("</tr>\n");
        }
    }

    try html.writeTableFooter(writer);
}

fn showTags(ctx: *gitweb.Context, repo: *gitweb.Repo, writer: anytype) !void {
    try writer.writeAll("<h3>Tags</h3>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        return;
    };
    defer git_repo.close();

    const tags = try git_repo.getTags(ctx.allocator);
    defer {
        for (tags) |tag| {
            ctx.allocator.free(tag.name);
        }
        ctx.allocator.free(tags);
    }

    if (tags.len == 0) {
        try writer.writeAll("<p>No tags found.</p>\n");
        return;
    }

    // Structure to hold tag data with timestamp for sorting
    const TagInfo = struct {
        tag: git.Tag,
        timestamp: i64,
        author_name: []const u8,
    };

    // Collect tag info with timestamps
    var tag_infos: std.ArrayList(TagInfo) = .empty;
    defer {
        for (tag_infos.items) |info| {
            @constCast(&info.tag.ref).free();
        }
        tag_infos.deinit(ctx.allocator);
    }

    for (tags) |tag| {
        _ = @constCast(&tag.ref).target() orelse continue;

        // Try to get tag object or fall back to commit
        var obj = @constCast(&tag.ref).peel(@import("../git.zig").c.GIT_OBJECT_COMMIT) catch continue;
        defer obj.free();

        var commit = try git_repo.lookupCommit(obj.id());
        defer commit.free();

        const author_sig = commit.author();
        const commit_time = commit.time();

        try tag_infos.append(ctx.allocator, TagInfo{
            .tag = tag,
            .timestamp = commit_time,
            .author_name = std.mem.span(author_sig.name),
        });
    }

    // Sort tags by timestamp (most recent first)
    std.mem.sort(TagInfo, tag_infos.items, {}, struct {
        fn lessThan(_: void, a: TagInfo, b: TagInfo) bool {
            return a.timestamp > b.timestamp;
        }
    }.lessThan);

    try html.writeTableHeader(writer, &[_][]const u8{ "Tag", "Download", "Author", "Age" });

    var shown: u32 = 0;
    for (tag_infos.items) |info| {
        if (shown >= ctx.cfg.summary_tags) break;
        shown += 1;

        const tag = info.tag;
        const commit_time = info.timestamp;
        const author_name = info.author_name;

        try html.writeTableRow(writer, null);

        // Tag name
        try writer.writeAll("<td>");
        if (ctx.repo) |r| {
            try writer.print("<a href='?r={s}&cmd=tag&h={s}'>{s}</a>", .{ r.name, tag.name, tag.name });
        } else {
            try writer.print("<a href='?cmd=tag&h={s}'>{s}</a>", .{ tag.name, tag.name });
        }
        try writer.writeAll("</td>");

        // Download links
        try writer.writeAll("<td>");
        if (ctx.repo) |r| {
            try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> ", .{ r.name, tag.name });
            try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{ r.name, tag.name });
        } else {
            try writer.print("<a href='?cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> ", .{tag.name});
            try writer.print("<a href='?cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{tag.name});
        }
        try writer.writeAll("</td>");

        // Author
        try writer.writeAll("<td>");
        try html.htmlEscape(writer, author_name);
        try writer.writeAll("</td>");

        // Age
        try writer.writeAll("<td class='age' data-timestamp='");
        try writer.print("{d}", .{commit_time});
        try writer.writeAll("'>");
        try shared.formatAge(writer, commit_time);
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
    }

    try html.writeTableFooter(writer);
}

pub fn about(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='about'>\n");
    try writer.print("<h2>About {s}</h2>\n", .{repo.name});

    // TODO: Read and render README file
    try writer.writeAll("<p>README content will be shown here.</p>\n");

    try writer.writeAll("</div>\n");
}

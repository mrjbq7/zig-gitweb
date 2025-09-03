const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn refs(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='refs'>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Show branches
    try showBranches(ctx, &git_repo, writer);

    // Show tags
    try showTags(ctx, &git_repo, writer);

    try writer.writeAll("</div>\n");
}

fn showBranches(ctx: *gitweb.Context, repo: *git.Repository, writer: anytype) !void {
    try writer.writeAll("<h2>Branches</h2>\n");

    const headers = [_][]const u8{ "Branch", "Commit", "Author", "Age" };
    try html.writeTableHeader(writer, &headers);

    // Get all branches
    var branch_list: ?*c.git_branch_iterator = null;
    if (c.git_branch_iterator_new(&branch_list, @ptrCast(repo.repo), c.GIT_BRANCH_ALL) != 0) {
        try writer.writeAll("<tr><td colspan='4'>Unable to get branches</td></tr>\n");
        try html.writeTableFooter(writer);
        return;
    }
    defer c.git_branch_iterator_free(branch_list);

    var ref: ?*c.git_reference = null;
    var branch_type: c.git_branch_t = undefined;

    var count: usize = 0;
    while (c.git_branch_next(&ref, &branch_type, branch_list) == 0) {
        defer c.git_reference_free(ref);

        const branch_name = c.git_reference_shorthand(ref) orelse continue;
        const target = c.git_reference_target(ref);

        if (target == null) continue;

        // Get commit info
        var commit = repo.lookupCommit(target.?) catch continue;
        defer commit.free();

        const oid_str = try git.oidToString(commit.id());
        const author = commit.author();
        const commit_time = commit.time();

        try html.writeTableRow(writer, if (count % 2 == 0) "even" else null);

        // Branch name (with remote indicator)
        try writer.writeAll("<td>");
        if (branch_type == c.GIT_BRANCH_REMOTE) {
            try writer.writeAll("<span style='color: #666'>remote/</span>");
        }
        if (ctx.repo) |r| {
            try writer.print("<a href='?r={s}&cmd=log&h={s}'>{s}</a>", .{ r.name, std.mem.span(branch_name), std.mem.span(branch_name) });
        } else {
            try writer.print("<a href='?cmd=log&h={s}'>{s}</a>", .{ std.mem.span(branch_name), std.mem.span(branch_name) });
        }

        // Show if this is the current branch
        if (branch_type == c.GIT_BRANCH_LOCAL) {
            var head: ?*c.git_reference = null;
            if (c.git_repository_head(&head, @ptrCast(repo.repo)) == 0) {
                defer c.git_reference_free(head);
                if (c.git_reference_cmp(ref, head) == 0) {
                    try writer.writeAll(" <strong>(HEAD)</strong>");
                }
            }
        }
        try writer.writeAll("</td>");

        // Commit hash
        try writer.writeAll("<td>");
        try shared.writeCommitLink(ctx, writer, &oid_str, oid_str[0..7]);
        try writer.writeAll("</td>");

        // Author
        try writer.writeAll("<td>");
        try html.htmlEscape(writer, parsing.truncateString(std.mem.span(author.name), 30));
        try writer.writeAll("</td>");

        // Age
        try writer.writeAll("<td class='age'>");
        try shared.formatAge(writer, commit_time);
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
        count += 1;
    }

    if (count == 0) {
        try writer.writeAll("<tr><td colspan='4'>No branches found</td></tr>\n");
    }

    try html.writeTableFooter(writer);
}

fn showTags(ctx: *gitweb.Context, repo: *git.Repository, writer: anytype) !void {
    try writer.writeAll("<h2>Tags</h2>\n");

    const headers = [_][]const u8{ "Tag", "Download", "Author", "Age" };
    try html.writeTableHeader(writer, &headers);

    // Get all tags
    var tag_names: c.git_strarray = undefined;
    if (c.git_tag_list(&tag_names, @ptrCast(repo.repo)) != 0) {
        try writer.writeAll("<tr><td colspan='4'>Unable to get tags</td></tr>\n");
        try html.writeTableFooter(writer);
        return;
    }
    defer c.git_strarray_dispose(&tag_names);

    // Process tags (newest first)
    var tags: std.ArrayList(TagInfo) = .empty;
    defer {
        for (tags.items) |*tag| {
            if (tag.tag_obj) |t| c.git_object_free(@ptrCast(t));
        }
        tags.deinit(ctx.allocator);
    }

    for (0..tag_names.count) |i| {
        const tag_name = tag_names.strings[i];

        var ref: ?*c.git_reference = null;
        const ref_name = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/tags/{s}", .{std.mem.span(tag_name)}, 0);
        defer ctx.allocator.free(ref_name);

        if (c.git_reference_lookup(&ref, @ptrCast(repo.repo), ref_name) != 0) continue;
        defer c.git_reference_free(ref);

        var tag_info = TagInfo{
            .name = std.mem.span(tag_name),
            .tag_obj = null,
            .target_oid = undefined,
            .tagger_time = 0,
            .tagger_name = "",
            .message = "",
        };

        const oid = c.git_reference_target(ref);
        if (oid == null) continue;

        // Check if it's an annotated tag
        var tag_obj: ?*c.git_tag = null;
        if (c.git_tag_lookup(&tag_obj, @ptrCast(repo.repo), oid) == 0) {
            // Annotated tag
            tag_info.tag_obj = tag_obj;
            tag_info.target_oid = c.git_tag_target_id(tag_obj).*;

            const tagger = c.git_tag_tagger(tag_obj);
            if (tagger != null) {
                tag_info.tagger_time = @intCast(tagger.*.when.time);
                tag_info.tagger_name = std.mem.span(tagger.*.name);
            }

            const msg = c.git_tag_message(tag_obj);
            if (msg != null) {
                tag_info.message = std.mem.span(msg);
            }
        } else {
            // Lightweight tag
            tag_info.target_oid = oid.*;

            // Get commit time for lightweight tags
            var commit = repo.lookupCommit(&tag_info.target_oid) catch continue;
            defer commit.free();
            tag_info.tagger_time = commit.time();
        }

        try tags.append(ctx.allocator, tag_info);
    }

    // Sort tags by time (newest first)
    std.sort.pdq(TagInfo, tags.items, {}, struct {
        fn lessThan(_: void, a: TagInfo, b: TagInfo) bool {
            return a.tagger_time > b.tagger_time;
        }
    }.lessThan);

    // Display tags
    for (tags.items, 0..) |tag, i| {
        try html.writeTableRow(writer, if (i % 2 == 0) "even" else null);

        // Tag name
        try writer.writeAll("<td>");
        const target_oid_str = try git.oidToString(@ptrCast(&tag.target_oid));
        if (ctx.repo) |r| {
            try writer.print("<a href='?r={s}&cmd=commit&id={s}'>{s}</a>", .{ r.name, target_oid_str, tag.name });
        } else {
            try writer.print("<a href='?cmd=commit&id={s}'>{s}</a>", .{ target_oid_str, tag.name });
        }

        // Show if annotated
        if (tag.tag_obj != null) {
            try writer.writeAll(" <span style='color: #666'>(annotated)</span>");
        }
        try writer.writeAll("</td>");

        // Download links
        try writer.writeAll("<td>");
        if (ctx.repo) |r| {
            try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> | ", .{ r.name, tag.name });
            try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{ r.name, tag.name });
        } else {
            try writer.print("<a href='?cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> | ", .{tag.name});
            try writer.print("<a href='?cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{tag.name});
        }
        try writer.writeAll("</td>");

        // Author/Tagger
        try writer.writeAll("<td>");
        if (tag.tag_obj != null and tag.tagger_name.len > 0) {
            try html.htmlEscape(writer, parsing.truncateString(tag.tagger_name, 30));
        } else {
            // For lightweight tags, show commit author
            var commit = repo.lookupCommit(&tag.target_oid) catch {
                try writer.writeAll("-");
                try writer.writeAll("</td><td>-</td></tr>\n");
                continue;
            };
            defer commit.free();

            const author = commit.author();
            try html.htmlEscape(writer, parsing.truncateString(std.mem.span(author.name), 30));
        }
        try writer.writeAll("</td>");

        // Age
        try writer.writeAll("<td class='age'>");
        if (tag.tagger_time > 0) {
            try shared.formatAge(writer, tag.tagger_time);
        } else {
            try writer.writeAll("-");
        }
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
    }

    if (tags.items.len == 0) {
        try writer.writeAll("<tr><td colspan='4'>No tags found</td></tr>\n");
    }

    try html.writeTableFooter(writer);
}

const TagInfo = struct {
    name: []const u8,
    tag_obj: ?*c.git_tag,
    target_oid: c.git_oid,
    tagger_time: i64,
    tagger_name: []const u8,
    message: []const u8,
};

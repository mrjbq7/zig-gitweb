const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = git.c;

pub fn commit(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='commit'>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Get the commit - either from ID or from branch/HEAD
    var commit_obj = if (ctx.query.get("id")) |commit_id| blk: {
        // Parse commit ID
        const oid = try git.stringToOid(commit_id);
        break :blk try git_repo.lookupCommit(&oid);
    } else blk: {
        // No ID specified, get latest commit from branch or HEAD
        const ref_name = ctx.query.get("h") orelse "HEAD";

        if (std.mem.eql(u8, ref_name, "HEAD")) {
            var head_ref = try git_repo.getHead();
            defer head_ref.free();

            const head_oid = head_ref.target() orelse return error.NoCommit;
            break :blk try git_repo.lookupCommit(head_oid);
        } else {
            // Try to get the reference
            var ref = git_repo.getReference(ref_name) catch {
                // Try with refs/heads/ prefix
                const full_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_name}, @as(u8, 0));
                defer ctx.allocator.free(full_ref);

                var ref2 = git_repo.getReference(full_ref) catch {
                    try writer.writeAll("<p>Unable to find branch reference.</p>\n");
                    try writer.writeAll("</div>\n");
                    return;
                };
                defer ref2.free();

                const oid = ref2.target() orelse return error.NoCommit;
                break :blk try git_repo.lookupCommit(oid);
            };
            defer ref.free();

            const oid = ref.target() orelse return error.NoCommit;
            break :blk try git_repo.lookupCommit(oid);
        }
    };
    defer commit_obj.free();

    const oid_str = try git.oidToString(commit_obj.id());

    try writer.print("<h2>Commit {s}", .{oid_str[0..7]});

    // Check for branches and tags at this commit
    var refs_found = false;

    // Check branches
    var branch_iter: ?*c.git_branch_iterator = null;
    if (c.git_branch_iterator_new(&branch_iter, @ptrCast(git_repo.repo), c.GIT_BRANCH_LOCAL) == 0) {
        defer c.git_branch_iterator_free(branch_iter);

        var ref: ?*c.git_reference = null;
        var branch_type: c.git_branch_t = undefined;

        while (c.git_branch_next(&ref, &branch_type, branch_iter) == 0) {
            defer c.git_reference_free(ref);

            const target = c.git_reference_target(ref);
            if (target == null) continue;

            if (c.git_oid_equal(commit_obj.id(), target) == 1) {
                const branch_name = c.git_reference_shorthand(ref);
                if (branch_name != null) {
                    if (!refs_found) {
                        try writer.writeAll(" ");
                        refs_found = true;
                    }
                    try writer.writeAll("<span class='ref-branch'>");
                    try html.htmlEscape(writer, std.mem.span(branch_name));
                    try writer.writeAll("</span> ");
                }
            }
        }
    }

    // Check tags
    var tag_names: c.git_strarray = undefined;
    if (c.git_tag_list(&tag_names, @ptrCast(git_repo.repo)) == 0) {
        defer c.git_strarray_dispose(&tag_names);

        for (0..tag_names.count) |i| {
            const tag_name = tag_names.strings[i];

            var ref: ?*c.git_reference = null;
            const ref_name = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/tags/{s}", .{std.mem.span(tag_name)}, 0);
            defer ctx.allocator.free(ref_name);

            if (c.git_reference_lookup(&ref, @ptrCast(git_repo.repo), ref_name) != 0) continue;
            defer c.git_reference_free(ref);

            const oid = c.git_reference_target(ref);
            if (oid == null) continue;

            // Check if it's an annotated tag
            var target_oid = oid.*;
            var tag_obj: ?*c.git_tag = null;
            if (c.git_tag_lookup(&tag_obj, @ptrCast(git_repo.repo), oid) == 0) {
                // Annotated tag - get the target commit
                target_oid = c.git_tag_target_id(tag_obj).*;
                c.git_object_free(@ptrCast(tag_obj));
            }

            if (c.git_oid_equal(commit_obj.id(), &target_oid) == 1) {
                if (!refs_found) {
                    try writer.writeAll(" ");
                    refs_found = true;
                }
                try writer.writeAll("<span class='ref-tag'>");
                try html.htmlEscape(writer, std.mem.span(tag_name));
                try writer.writeAll("</span> ");
            }
        }
    }

    try writer.writeAll("</h2>\n");

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
    try writer.writeAll("<h3>Changes</h3>\n");

    // Get the commit SHA for use in log links
    const commit_oid_str = try git.oidToString(commit_obj.id());

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

    // Show file list with per-file stats
    const num_deltas = diff.numDeltas();
    try writer.writeAll("<div class='diff-filelist'>\n");
    try writer.writeAll("<table>\n");

    for (0..num_deltas) |i| {
        const delta = diff.getDelta(i).?;
        const old_file = delta.*.old_file;
        const new_file = delta.*.new_file;

        // Get per-file stats
        var patch: ?*c.git_patch = null;
        var additions: usize = 0;
        var deletions_count: usize = 0;

        if (c.git_patch_from_diff(&patch, @ptrCast(diff.diff), i) == 0) {
            defer c.git_patch_free(patch);

            var total: usize = 0;
            var adds: usize = 0;
            var dels: usize = 0;
            _ = c.git_patch_line_stats(&total, &adds, &dels, patch);
            additions = adds;
            deletions_count = dels;
        }

        try writer.writeAll("<tr><td>");

        // File name with status
        switch (delta.*.status) {
            c.GIT_DELTA_ADDED => {
                try writer.writeAll("<span style='color: green'>A</span> ");
                try html.htmlEscape(writer, std.mem.span(new_file.path));
            },
            c.GIT_DELTA_DELETED => {
                try writer.writeAll("<span style='color: red'>D</span> ");
                try html.htmlEscape(writer, std.mem.span(old_file.path));
            },
            c.GIT_DELTA_MODIFIED => {
                try writer.writeAll("M ");
                try html.htmlEscape(writer, std.mem.span(new_file.path));
            },
            c.GIT_DELTA_RENAMED => {
                try writer.writeAll("R ");
                try html.htmlEscape(writer, std.mem.span(old_file.path));
                try writer.writeAll(" → ");
                try html.htmlEscape(writer, std.mem.span(new_file.path));
            },
            c.GIT_DELTA_COPIED => {
                try writer.writeAll("C ");
                try html.htmlEscape(writer, std.mem.span(old_file.path));
                try writer.writeAll(" → ");
                try html.htmlEscape(writer, std.mem.span(new_file.path));
            },
            else => {
                try html.htmlEscape(writer, std.mem.span(new_file.path));
            },
        }

        try writer.writeAll("</td><td style='text-align: right; padding-left: 20px;'>");

        // Show additions/deletions for this file
        if (additions > 0 or deletions_count > 0) {
            try writer.print("<span style='color: green'>+{d}</span> <span style='color: red'>-{d}</span>", .{ additions, deletions_count });
        }

        try writer.writeAll("</td><td style='padding-left: 20px;'>");

        // Add links for the file
        // Use the appropriate file path based on the status
        const file_path = switch (delta.*.status) {
            c.GIT_DELTA_DELETED => std.mem.span(old_file.path),
            else => std.mem.span(new_file.path),
        };

        // Don't show view/blame links for deleted files
        if (delta.*.status != c.GIT_DELTA_DELETED) {
            // View link (blob at this commit)
            try writer.writeAll("<a href='?");
            if (ctx.repo) |r| {
                try writer.print("r={s}&", .{r.name});
            }
            try writer.writeAll("cmd=blob");
            try writer.print("&id={s}", .{commit_oid_str});
            try writer.writeAll("&path=");
            try html.urlEncodePath(writer, file_path);
            try writer.writeAll("'>view</a> | ");

            // Blame link
            try writer.writeAll("<a href='?");
            if (ctx.repo) |r| {
                try writer.print("r={s}&", .{r.name});
            }
            try writer.writeAll("cmd=blame");
            try writer.print("&id={s}", .{commit_oid_str});
            try writer.writeAll("&path=");
            try html.urlEncodePath(writer, file_path);
            try writer.writeAll("'>blame</a> | ");
        }

        // Log link (history up to this commit)
        try writer.writeAll("<a href='?");
        if (ctx.repo) |r| {
            try writer.print("r={s}&", .{r.name});
        }
        try writer.writeAll("cmd=log");

        // Use the commit SHA as the starting point for the log
        try writer.print("&id={s}", .{commit_oid_str});

        try writer.writeAll("&path=");
        try html.urlEncodePath(writer, file_path);
        try writer.writeAll("'>log</a>");

        try writer.writeAll("</td></tr>\n");
    }

    try writer.writeAll("</table>\n");
    try writer.writeAll("</div>\n");

    // Show each file's diff in a separate container
    try writer.writeAll("<div class='diff-files'>\n");

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

        // Show this file's diff content
        try writer.writeAll("<pre class='diff'>\n");

        // Create a patch for just this file
        var patch: ?*c.git_patch = null;
        if (c.git_patch_from_diff(&patch, @ptrCast(diff.diff), i) == 0) {
            defer c.git_patch_free(patch);

            // Print the patch content
            const callback_data = struct {
                writer: @TypeOf(writer),

                fn printLine(
                    cb_delta: [*c]const c.git_diff_delta,
                    cb_hunk: [*c]const c.git_diff_hunk,
                    cb_line: [*c]const c.git_diff_line,
                    payload: ?*anyopaque,
                ) callconv(.c) c_int {
                    _ = cb_delta;
                    _ = cb_hunk;

                    const self = @as(*@This(), @ptrCast(@alignCast(payload.?)));

                    // Write line with appropriate styling
                    switch (cb_line.*.origin) {
                        '+' => self.writer.writeAll("<span class='add'>+") catch return -1,
                        '-' => self.writer.writeAll("<span class='del'>-") catch return -1,
                        '@' => self.writer.writeAll("<span class='hunk'>@") catch return -1,
                        'F' => {}, // File header lines - don't print the 'F'
                        ' ' => self.writer.writeByte(' ') catch return -1, // Context line
                        else => {}, // Don't print other origin characters
                    }

                    const content = @as([*]const u8, @ptrCast(cb_line.*.content))[0..@intCast(cb_line.*.content_len)];
                    html.htmlEscape(self.writer, content) catch return -1;

                    switch (cb_line.*.origin) {
                        '+', '-', '@' => self.writer.writeAll("</span>") catch return -1,
                        else => {},
                    }

                    if (!std.mem.endsWith(u8, content, "\n")) {
                        self.writer.writeAll("\n") catch return -1;
                    }

                    return 0;
                }
            }{ .writer = writer };

            _ = c.git_patch_print(patch, @TypeOf(callback_data).printLine, @ptrCast(@constCast(&callback_data)));
        }

        try writer.writeAll("</pre>\n");
        try writer.writeAll("</div>\n");
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

const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = git.c;

const RefInfo = struct {
    name: []const u8,
    ref_type: enum { branch, tag },
};

pub fn log(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='log'>\n");

    // Get path parameter early
    const path = ctx.query.get("path");

    // Show title with path if filtering
    if (path) |p| {
        try writer.writeAll("<h2>Commit Log for ");
        try html.htmlEscape(writer, p);
        try writer.writeAll("</h2>\n");
    } else {
        try writer.writeAll("<h2>Commit Log</h2>\n");
    }

    // Add expand/collapse toggle
    const showmsg = ctx.query.get("showmsg");
    const expanded = showmsg != null and std.mem.eql(u8, showmsg.?, "1");

    try writer.writeAll("<div class='log-controls'>\n");
    if (ctx.repo) |r| {
        if (expanded) {
            try writer.print("<a href='?r={s}&cmd=log", .{r.name});
            if (ctx.query.get("id")) |id| {
                try writer.print("&id={s}", .{id});
            } else if (ctx.query.get("h")) |h| {
                try writer.print("&h={s}", .{h});
            }
            if (path) |p| {
                try writer.writeAll("&path=");
                try html.urlEncodePath(writer, p);
            }
            try writer.writeAll("'>Collapse</a>\n");
        } else {
            try writer.print("<a href='?r={s}&cmd=log&showmsg=1", .{r.name});
            if (ctx.query.get("id")) |id| {
                try writer.print("&id={s}", .{id});
            } else if (ctx.query.get("h")) |h| {
                try writer.print("&h={s}", .{h});
            }
            if (path) |p| {
                try writer.writeAll("&path=");
                try html.urlEncodePath(writer, p);
            }
            try writer.writeAll("'>Expand</a>\n");
        }
    }
    try writer.writeAll("</div>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Build a map of commit OIDs to their refs (branches and tags)
    var refs_map = std.StringHashMap(std.ArrayList(RefInfo)).init(ctx.allocator);
    defer {
        var iter = refs_map.iterator();
        while (iter.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*); // Free the key
            for (entry.value_ptr.items) |*ref_info| {
                ctx.allocator.free(ref_info.name);
            }
            entry.value_ptr.deinit(ctx.allocator);
        }
        refs_map.deinit();
    }

    // Collect all branches
    var branch_iter: ?*c.git_branch_iterator = null;
    if (c.git_branch_iterator_new(&branch_iter, @ptrCast(git_repo.repo), c.GIT_BRANCH_LOCAL) == 0) {
        defer c.git_branch_iterator_free(branch_iter);

        var ref: ?*c.git_reference = null;
        var branch_type: c.git_branch_t = undefined;

        while (c.git_branch_next(&ref, &branch_type, branch_iter) == 0) {
            defer c.git_reference_free(ref);

            const branch_name = c.git_reference_shorthand(ref);
            if (branch_name == null) continue;

            const target = c.git_reference_target(ref);
            if (target == null) continue;

            const oid_str = try git.oidToString(target);
            const oid_key = try ctx.allocator.dupe(u8, &oid_str);

            var entry = try refs_map.getOrPut(oid_key);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(RefInfo).empty;
            } else {
                ctx.allocator.free(oid_key); // Free the duplicate key
            }

            try entry.value_ptr.append(ctx.allocator, .{
                .name = try ctx.allocator.dupe(u8, std.mem.span(branch_name)),
                .ref_type = .branch,
            });
        }
    }

    // Collect all tags
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

            const oid_str = try git.oidToString(&target_oid);
            const oid_key = try ctx.allocator.dupe(u8, &oid_str);

            var entry = try refs_map.getOrPut(oid_key);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(RefInfo).empty;
            } else {
                ctx.allocator.free(oid_key); // Free the duplicate key
            }

            try entry.value_ptr.append(ctx.allocator, .{
                .name = try ctx.allocator.dupe(u8, std.mem.span(tag_name)),
                .ref_type = .tag,
            });
        }
    }

    // Get starting point - prefer id (commit hash) over h (branch/ref)
    const commit_id = ctx.query.get("id");
    const ref_name = ctx.query.get("h") orelse "HEAD";
    const offset_str = ctx.query.get("ofs") orelse "0";
    const offset = std.fmt.parseInt(u32, offset_str, 10) catch 0;

    // Create revision walker
    var walk = try git_repo.revwalk();
    defer walk.free();

    // Set starting point
    if (commit_id) |id| {
        // If we have a commit ID, start from that specific commit
        if (git.stringToOid(id)) |oid| {
            // Use the C API directly to push a specific commit OID
            if (c.git_revwalk_push(walk.walk, &oid) != 0) {
                // Failed to push commit, fall back to ref_name
                if (std.mem.eql(u8, ref_name, "HEAD")) {
                    try walk.pushHead();
                } else {
                    try walk.pushHead(); // Just use HEAD as fallback
                }
            }
        } else |_| {
            // If parsing fails, fall back to ref_name
            if (std.mem.eql(u8, ref_name, "HEAD")) {
                try walk.pushHead();
            } else {
                // Try as branch/tag/ref
                const full_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_name}, @as(u8, 0));
                defer ctx.allocator.free(full_ref);
                walk.pushRef(full_ref) catch {
                    const tag_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/tags/{s}", .{ref_name}, @as(u8, 0));
                    defer ctx.allocator.free(tag_ref);
                    walk.pushRef(tag_ref) catch {
                        walk.pushRef(ref_name) catch {
                            try walk.pushHead();
                        };
                    };
                };
            }
        }
    } else {
        // No commit ID, use branch/ref
        if (std.mem.eql(u8, ref_name, "HEAD")) {
            try walk.pushHead();
        } else {
            // Try as full reference first (refs/heads/branch)
            const full_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_name}, @as(u8, 0));
            defer ctx.allocator.free(full_ref);
            walk.pushRef(full_ref) catch {
                // If that fails, try as tag (refs/tags/tagname)
                const tag_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/tags/{s}", .{ref_name}, @as(u8, 0));
                defer ctx.allocator.free(tag_ref);
                walk.pushRef(tag_ref) catch {
                    // If that also fails, try the name as-is (might be a full ref already)
                    walk.pushRef(ref_name) catch {
                        // Fall back to HEAD if nothing works
                        try walk.pushHead();
                    };
                };
            };
        }
    }

    // Set sorting
    walk.setSorting(@intCast(c.GIT_SORT_TIME | if (ctx.repo.?.commit_sort == .topo) c.GIT_SORT_TOPOLOGICAL else 0));

    // Start log list
    try writer.writeAll("<div class='log-list'>\n");

    // Skip to offset
    var skip = offset;
    while (skip > 0) : (skip -= 1) {
        _ = walk.next() orelse break;
    }

    // Display commits
    var count: u32 = 0;
    var total: u32 = offset;

    while (walk.next()) |oid| {
        if (count >= ctx.cfg.max_commit_count) break;

        var commit = try git_repo.lookupCommit(&oid);
        defer commit.free();

        // If path filter is specified, check if commit touches the path
        if (path) |filter_path| {
            if (!try commitTouchesPath(&git_repo, &commit, filter_path)) {
                continue;
            }
        }

        count += 1;
        total += 1;

        const oid_str = try git.oidToString(commit.id());
        const author_sig = commit.author();
        const commit_time = commit.time();
        const summary = commit.summary();

        var oid_buf: [40]u8 = undefined;
        @memcpy(&oid_buf, oid_str[0..40]);

        // Determine message to show
        const message = if (expanded)
            commit.message()
        else
            parsing.truncateString(summary, @intCast(ctx.cfg.max_msg_len));

        // Get refs for this commit if any
        const refs = if (refs_map.get(&oid_str)) |ref_list|
            ref_list.items
        else
            null;

        // Start log item manually to include stats
        try writer.writeAll("<div class='log-item'>\n");

        // First line: commit message with inline refs
        try writer.writeAll("<div class='log-message'>\n");
        try html.htmlEscape(writer, message);

        // Show refs inline if present
        if (refs) |ref_list| {
            try writer.writeAll(" ");
            for (ref_list) |ref_info| {
                switch (ref_info.ref_type) {
                    .branch => {
                        try writer.writeAll("<span class='ref-branch'>");
                        try html.htmlEscape(writer, ref_info.name);
                        try writer.writeAll("</span> ");
                    },
                    .tag => {
                        try writer.writeAll("<span class='ref-tag'>");
                        try html.htmlEscape(writer, ref_info.name);
                        try writer.writeAll("</span> ");
                    },
                }
            }
        }

        try writer.writeAll("</div>\n");

        // Second line: metadata
        try writer.writeAll("<div class='log-meta'>\n");

        // Commit hash
        try writer.writeAll("<span class='log-hash'>");
        try shared.writeCommitLink(ctx, writer, &oid_buf, oid_buf[0..7]);
        try writer.writeAll("</span>");

        // Author
        try writer.writeAll("<span class='log-author'>");
        try html.htmlEscape(writer, parsing.truncateString(std.mem.span(author_sig.name), 20));
        try writer.writeAll("</span>");

        // Age
        try writer.print("<span class='log-age' data-timestamp='{d}'>", .{commit_time});
        try shared.formatAge(writer, commit_time);
        try writer.writeAll("</span>");

        // File/line statistics
        if (ctx.cfg.enable_log_filecount or ctx.cfg.enable_log_linecount) {
            const stats = try getCommitStats(&git_repo, &commit);

            try writer.writeAll("<span class='log-stats'>");
            if (ctx.cfg.enable_log_filecount) {
                try writer.print("{d} file{s} ", .{ stats.files_changed, if (stats.files_changed == 1) "" else "s" });
            }
            if (ctx.cfg.enable_log_linecount) {
                try writer.print("(<span class='insertions'>+{d}</span>, ", .{stats.insertions});
                try writer.print("<span class='deletions'>-{d}</span>)", .{stats.deletions});
            }
            try writer.writeAll("</span>");
        }

        try writer.writeAll("</div>\n"); // log-meta
        try writer.writeAll("</div>\n"); // log-item
    }

    try writer.writeAll("</div>\n"); // log-list

    // Pagination
    try writer.writeAll("<div class='pagination'>\n");

    if (offset > 0) {
        const prev_offset = if (offset > ctx.cfg.max_commit_count) offset - ctx.cfg.max_commit_count else 0;
        if (ctx.repo) |r| {
            try writer.print("<a href='?r={s}&cmd=log&h={s}&ofs={d}", .{ r.name, ref_name, prev_offset });
        } else {
            try writer.print("<a href='?cmd=log&h={s}&ofs={d}", .{ ref_name, prev_offset });
        }
        if (expanded) {
            try writer.writeAll("&showmsg=1");
        }
        try writer.writeAll("'>← Previous</a> ");
    }

    if (count == ctx.cfg.max_commit_count) {
        if (ctx.repo) |r| {
            try writer.print("<a href='?r={s}&cmd=log&h={s}&ofs={d}", .{ r.name, ref_name, total });
        } else {
            try writer.print("<a href='?cmd=log&h={s}&ofs={d}", .{ ref_name, total });
        }
        if (expanded) {
            try writer.writeAll("&showmsg=1");
        }
        try writer.writeAll("'>Next →</a>");
    }

    try writer.writeAll("</div>\n");
    try writer.writeAll("</div>\n");
}

fn commitTouchesPath(repo: *git.Repository, commit: *git.Commit, path: []const u8) !bool {
    // For performance, we'll use a simpler approach:
    // Create a diff with pathspec filtering

    const parent_count = commit.parentCount();

    // Get commit tree
    var commit_tree = try commit.tree();
    defer commit_tree.free();

    // For initial commit, check if path exists
    if (parent_count == 0) {
        // Check if path exists in this commit
        var path_parts = std.mem.tokenizeAny(u8, path, "/");
        var current_tree = commit_tree;

        while (path_parts.next()) |part| {
            const entry = current_tree.entryByName(part);
            if (entry == null) {
                if (&current_tree != &commit_tree) current_tree.free();
                return false;
            }

            if (path_parts.peek() != null) {
                if (c.git_tree_entry_type(@ptrCast(entry)) == c.GIT_OBJECT_TREE) {
                    const tree_oid = c.git_tree_entry_id(@ptrCast(entry));
                    const new_tree = try repo.lookupTree(@constCast(tree_oid));
                    if (&current_tree != &commit_tree) {
                        current_tree.free();
                    }
                    current_tree = new_tree;
                } else {
                    if (&current_tree != &commit_tree) current_tree.free();
                    return false;
                }
            }
        }

        if (&current_tree != &commit_tree) current_tree.free();
        return true;
    }

    // For commits with parents, use diff options with pathspec
    var diff_opts: c.git_diff_options = undefined;
    _ = c.git_diff_options_init(&diff_opts, c.GIT_DIFF_OPTIONS_VERSION);

    // Set up pathspec for the path we're interested in
    // Need null-terminated string for C API
    var path_buf: [4096]u8 = undefined;
    const c_path = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});

    const pathspec_array: c.git_strarray = .{
        .strings = @constCast(&[_][*c]u8{c_path.ptr}),
        .count = 1,
    };
    diff_opts.pathspec = pathspec_array;

    // Only need to know if files changed, not the actual changes
    diff_opts.flags |= c.GIT_DIFF_SKIP_BINARY_CHECK;
    diff_opts.flags |= c.GIT_DIFF_INCLUDE_UNTRACKED;

    var parent = try commit.parent(0);
    defer parent.free();

    var parent_tree = try parent.tree();
    defer parent_tree.free();

    // Create diff with pathspec
    var diff = try git.Diff.treeToTree(repo.repo, parent_tree.tree, commit_tree.tree, @ptrCast(&diff_opts));
    defer diff.free();

    // If there are any deltas, the path was touched
    return diff.numDeltas() > 0;
}

const CommitStats = struct {
    files_changed: usize,
    insertions: usize,
    deletions: usize,
};

fn getCommitStats(repo: *git.Repository, commit: *git.Commit) !CommitStats {
    var stats: CommitStats = undefined;
    stats.files_changed = 0;
    stats.insertions = 0;
    stats.deletions = 0;

    // Get parent commit
    if (commit.parentCount() == 0) {
        // Initial commit - compare against empty tree
        var tree = try commit.tree();
        defer tree.free();

        var diff = try git.Diff.treeToTree(repo.repo, null, tree.tree, null);
        defer diff.free();

        var diff_stats = try diff.getStats();
        defer diff_stats.free();

        stats.files_changed = @as(usize, diff_stats.filesChanged());
        stats.insertions = @as(usize, diff_stats.insertions());
        stats.deletions = @as(usize, diff_stats.deletions());
    } else {
        // Normal commit - compare against first parent
        var parent = try commit.parent(0);
        defer parent.free();

        var parent_tree = try parent.tree();
        defer parent_tree.free();

        var commit_tree = try commit.tree();
        defer commit_tree.free();

        var diff = try git.Diff.treeToTree(repo.repo, parent_tree.tree, commit_tree.tree, null);
        defer diff.free();

        var diff_stats = try diff.getStats();
        defer diff_stats.free();

        stats.files_changed = @as(usize, diff_stats.filesChanged());
        stats.insertions = @as(usize, diff_stats.insertions());
        stats.deletions = @as(usize, diff_stats.deletions());
    }

    return stats;
}

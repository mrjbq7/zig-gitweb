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
    _ = ctx.repo orelse return error.NoRepo;

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
            try writer.print("<a class='btn' href='?r={s}&cmd=log", .{r.name});
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
            try writer.print("<a class='btn' href='?r={s}&cmd=log&showmsg=1", .{r.name});
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

    var git_repo = (try shared.openRepositoryWithError(ctx, writer)) orelse return;
    defer git_repo.close();

    // Build a map of commit OIDs to their refs (branches and tags)
    var refs_map_raw = try shared.collectRefsMap(ctx, &git_repo);
    defer {
        var iter = refs_map_raw.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.items) |item| {
                ctx.allocator.free(item);
            }
            entry.value_ptr.deinit(ctx.allocator);
            ctx.allocator.free(entry.key_ptr.*);
        }
        refs_map_raw.deinit();
    }

    // Convert to the expected format with RefInfo
    var refs_map = std.StringHashMap(std.ArrayList(RefInfo)).init(ctx.allocator);
    defer {
        var iter = refs_map.iterator();
        while (iter.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |*ref_info| {
                ctx.allocator.free(ref_info.name);
            }
            entry.value_ptr.deinit(ctx.allocator);
        }
        refs_map.deinit();
    }

    // Convert refs from raw map to RefInfo format
    var raw_iter = refs_map_raw.iterator();
    while (raw_iter.next()) |entry| {
        const key = try ctx.allocator.dupe(u8, entry.key_ptr.*);
        var result = try refs_map.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(RefInfo).empty;
        } else {
            ctx.allocator.free(key);
        }

        for (entry.value_ptr.items) |name| {
            // Determine if it's a branch or tag based on name conventions
            const is_tag = std.mem.startsWith(u8, name, "v") or std.mem.indexOf(u8, name, ".") != null;
            try result.value_ptr.append(ctx.allocator, .{
                .name = try ctx.allocator.dupe(u8, name),
                .ref_type = if (is_tag) .tag else .branch,
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
                // Try as branch/tag/ref using stack buffer
                var ref_buf: [256]u8 = undefined;
                const full_ref = try shared.formatBranchRef(&ref_buf, ref_name);
                walk.pushRef(full_ref) catch {
                    const tag_ref = try shared.formatTagRef(&ref_buf, ref_name);
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
            // Try as full reference first using stack buffer
            var ref_buf: [256]u8 = undefined;
            const full_ref = try shared.formatBranchRef(&ref_buf, ref_name);
            walk.pushRef(full_ref) catch {
                // If that fails, try as tag
                const tag_ref = try shared.formatTagRef(&ref_buf, ref_name);
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
        const full_message = commit.message();

        var oid_buf: [40]u8 = undefined;
        @memcpy(&oid_buf, oid_str[0..40]);

        // Determine message to show
        // When collapsed: show full first line (subject)
        // When expanded: show complete message
        const parsed_msg = parsing.parseCommitMessage(full_message);
        const message = if (expanded)
            full_message
        else
            parsed_msg.subject;

        // Get refs for this commit if any
        const refs = if (refs_map.get(&oid_str)) |ref_list|
            ref_list.items
        else
            null;

        // Start log item manually to include stats
        try writer.writeAll("<div class='log-item'>\n");

        // First line: commit message with inline refs
        try writer.writeAll("<div class='log-message'>\n");

        // When expanded, convert newlines to <br> tags
        if (expanded) {
            var lines = std.mem.splitScalar(u8, message, '\n');
            var first_line = true;
            while (lines.next()) |line| {
                if (!first_line) {
                    try writer.writeAll("<br/>\n");
                }
                try html.htmlEscape(writer, line);
                first_line = false;
            }
        } else {
            // When collapsed, just show the first line (no trailing newline)
            try html.htmlEscape(writer, message);
        }

        // Show refs inline if present (on the same line)
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

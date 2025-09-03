const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");

const c = git.c;

pub fn diff(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='diff'>\n");
    try writer.writeAll("<h2>Diff</h2>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Get the first commit - either from ID or from branch/HEAD
    const commit1_oid = if (ctx.query.get("id")) |commit_id| blk: {
        // Parse commit ID
        break :blk try git.stringToOid(commit_id);
    } else blk: {
        // No ID specified, get latest commit from branch or HEAD
        const ref_name = ctx.query.get("h") orelse "HEAD";

        if (std.mem.eql(u8, ref_name, "HEAD")) {
            var head_ref = try git_repo.getHead();
            defer head_ref.free();

            const head_oid = head_ref.target() orelse {
                try writer.writeAll("<p>Unable to get HEAD commit.</p>\n");
                try writer.writeAll("</div>\n");
                return;
            };
            break :blk head_oid.*;
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

                const oid = ref2.target() orelse {
                    try writer.writeAll("<p>Unable to get branch commit.</p>\n");
                    try writer.writeAll("</div>\n");
                    return;
                };
                break :blk oid.*;
            };
            defer ref.free();

            const oid = ref.target() orelse {
                try writer.writeAll("<p>Unable to get branch commit.</p>\n");
                try writer.writeAll("</div>\n");
                return;
            };
            break :blk oid.*;
        }
    };

    // Get the second commit ID (parent if not specified)
    const id2 = ctx.query.get("id2") orelse blk: {
        // If id2 not specified, diff against parent
        var commit = try git_repo.lookupCommit(&commit1_oid);
        defer commit.free();

        if (commit.parentCount() > 0) {
            var parent = try commit.parent(0);
            defer parent.free();
            const parent_oid_str = try git.oidToString(parent.id());
            ctx.query.set("id2", &parent_oid_str) catch {};
            break :blk ctx.query.get("id2") orelse {
                try writer.writeAll("<p>No parent commit to diff against.</p>\n");
                try writer.writeAll("</div>\n");
                return;
            };
        } else {
            try writer.writeAll("<p>No parent commit to diff against.</p>\n");
            try writer.writeAll("</div>\n");
            return;
        }
    };

    const path = ctx.query.get("path");
    const context_lines_str = ctx.query.get("context") orelse "3";
    const context_lines = std.fmt.parseInt(u32, context_lines_str, 10) catch 3;

    // Parse second commit ID
    const oid2 = try git.stringToOid(id2);

    // Get the commits
    var commit1 = try git_repo.lookupCommit(&commit1_oid);
    defer commit1.free();

    var commit2 = try git_repo.lookupCommit(&oid2);
    defer commit2.free();

    // Get trees
    var tree1 = try commit1.tree();
    defer tree1.free();

    var tree2 = try commit2.tree();
    defer tree2.free();

    // Create diff options
    var diff_opts = std.mem.zeroes(c.git_diff_options);
    _ = c.git_diff_options_init(&diff_opts, c.GIT_DIFF_OPTIONS_VERSION);
    diff_opts.context_lines = context_lines;

    if (path) |p| {
        // Set path filter
        var pathspec = std.mem.zeroes(c.git_strarray);
        const c_path = try std.heap.c_allocator.dupeZ(u8, p);
        defer std.heap.c_allocator.free(c_path);

        const c_path_ptr: [*c]u8 = @constCast(c_path.ptr);
        pathspec.strings = @constCast(&c_path_ptr);
        pathspec.count = 1;
        diff_opts.pathspec = pathspec;
    }

    // Create diff
    var diff_obj = try git.Diff.treeToTree(git_repo.repo, tree2.tree, tree1.tree, @as(?*c.git_diff_options, &diff_opts));
    defer diff_obj.free();

    // Display diff header
    const oid1_str = try git.oidToString(&commit1_oid);
    const oid2_str = try git.oidToString(&oid2);

    try writer.writeAll("<div class='diff-header'>\n");
    try writer.print("<strong>Comparing:</strong> ", .{});
    try shared.writeCommitLink(ctx, writer, &oid2_str, oid2_str[0..7]);
    try writer.writeAll(" ... ");
    try shared.writeCommitLink(ctx, writer, &oid1_str, oid1_str[0..7]);

    if (path) |p| {
        try writer.print(" (filtered to: {s})", .{p});
    }

    try writer.writeAll("</div>\n");

    // Get statistics
    var stats = try diff_obj.getStats();
    defer stats.free();

    const files_changed = stats.filesChanged();
    const insertions = stats.insertions();
    const deletions = stats.deletions();

    try writer.writeAll("<div class='diffstat'>\n");
    try writer.print("{d} file{s} changed, ", .{ files_changed, if (files_changed == 1) "" else "s" });
    try writer.print("<span style='color: green'>{d} insertion{s}(+)</span>, ", .{ insertions, if (insertions == 1) "" else "s" });
    try writer.print("<span style='color: red'>{d} deletion{s}(-)</span>\n", .{ deletions, if (deletions == 1) "" else "s" });
    try writer.writeAll("</div>\n");

    // Display diff type selector
    const diff_type = ctx.query.get("dt") orelse "unified";

    try writer.writeAll("<div class='diff-options'>\n");
    try writer.writeAll("View: ");

    if (std.mem.eql(u8, diff_type, "unified")) {
        try writer.writeAll("<strong>Unified</strong> | ");
    } else {
        try writer.print("<a href='?r={s}&cmd=diff&id={s}&id2={s}&dt=unified'>Unified</a> | ", .{ repo.name, oid1_str, oid2_str });
    }

    if (std.mem.eql(u8, diff_type, "ssdiff")) {
        try writer.writeAll("<strong>Side-by-side</strong> | ");
    } else {
        try writer.print("<a href='?r={s}&cmd=diff&id={s}&id2={s}&dt=ssdiff'>Side-by-side</a> | ", .{ repo.name, oid1_str, oid2_str });
    }

    if (std.mem.eql(u8, diff_type, "stat")) {
        try writer.writeAll("<strong>Stat only</strong>");
    } else {
        try writer.print("<a href='?r={s}&cmd=diff&id={s}&id2={s}&dt=stat'>Stat only</a>", .{ repo.name, oid1_str, oid2_str });
    }

    try writer.writeAll("</div>\n");

    // Display diff based on type
    if (std.mem.eql(u8, diff_type, "stat")) {
        try displayDiffStat(&diff_obj, writer);
    } else if (std.mem.eql(u8, diff_type, "ssdiff")) {
        try displaySideBySideDiff(&diff_obj, writer);
    } else {
        try displayUnifiedDiff(&diff_obj, writer);
    }

    try writer.writeAll("</div>\n");
}

fn displayUnifiedDiff(diff_obj: *git.Diff, writer: anytype) !void {
    // Iterate through each file in the diff
    const num_deltas = diff_obj.numDeltas();
    
    for (0..num_deltas) |delta_idx| {
        const delta = diff_obj.getDelta(delta_idx) orelse continue;
        
        // File header with clear visual separation
        try writer.writeAll("<div class='diff-file'>\n");
        try writer.writeAll("<div class='diff-file-header'>\n");
        
        // Show file path changes
        const old_path = std.mem.span(delta.old_file.path);
        const new_path = std.mem.span(delta.new_file.path);
        
        if (std.mem.eql(u8, old_path, new_path)) {
            try writer.print("<strong>{s}</strong>", .{new_path});
        } else {
            try writer.print("<strong>{s} → {s}</strong>", .{ old_path, new_path });
        }
        
        // Show file status
        const status_str = switch (delta.status) {
            c.GIT_DELTA_ADDED => " (new file)",
            c.GIT_DELTA_DELETED => " (deleted)",
            c.GIT_DELTA_MODIFIED => " (modified)",
            c.GIT_DELTA_RENAMED => " (renamed)",
            c.GIT_DELTA_COPIED => " (copied)",
            c.GIT_DELTA_TYPECHANGE => " (type changed)",
            else => "",
        };
        try writer.writeAll(status_str);
        
        try writer.writeAll("</div>\n");
        
        // File diff content
        try writer.writeAll("<pre class='diff'>\n");
        
        // Print only this file's patch
        var patch: ?*c.git_patch = null;
        if (c.git_patch_from_diff(&patch, @ptrCast(diff_obj.diff), delta_idx) == 0) {
            defer c.git_patch_free(patch);
            
            var buf = std.mem.zeroes(c.git_buf);
            defer c.git_buf_dispose(&buf);
            
            if (c.git_patch_to_buf(&buf, patch) == 0) {
                const patch_str = buf.ptr[0..buf.size];
                // Skip the file header lines that git_patch_to_buf adds
                if (std.mem.indexOf(u8, patch_str, "@@")) |first_hunk| {
                    // Find the start of the line containing @@
                    var line_start = first_hunk;
                    while (line_start > 0 and patch_str[line_start - 1] != '\n') {
                        line_start -= 1;
                    }
                    const lines_to_show = patch_str[line_start..];
                    
                    // Parse and display the patch lines
                    var lines = std.mem.tokenizeScalar(u8, lines_to_show, '\n');
                    while (lines.next()) |line_content| {
                        if (line_content.len == 0) continue;
                        
                        const origin = line_content[0];
                        const content = if (line_content.len > 1) line_content[1..] else "";
                        
                        switch (origin) {
                            '@' => {
                                try writer.writeAll("<span class='hunk'>@");
                                try html.htmlEscape(writer, content);
                                try writer.writeAll("</span>\n");
                            },
                            '+' => {
                                try writer.writeAll("<span class='add'>+");
                                try html.htmlEscape(writer, content);
                                try writer.writeAll("</span>\n");
                            },
                            '-' => {
                                try writer.writeAll("<span class='del'>-");
                                try html.htmlEscape(writer, content);
                                try writer.writeAll("</span>\n");
                            },
                            ' ' => {
                                try writer.writeAll(" ");
                                try html.htmlEscape(writer, content);
                                try writer.writeAll("\n");
                            },
                            else => {
                                try html.htmlEscape(writer, line_content);
                                try writer.writeAll("\n");
                            },
                        }
                    }
                }
            }
        }
        
        try writer.writeAll("</pre>\n");
        try writer.writeAll("</div>\n");
    }
}

fn displaySideBySideDiff(diff_obj: *git.Diff, writer: anytype) !void {
    try writer.writeAll("<div class='ssdiff-container'>\n");

    const num_deltas = diff_obj.numDeltas();

    for (0..num_deltas) |i| {
        var patch: ?*c.git_patch = null;
        if (c.git_patch_from_diff(&patch, diff_obj.diff, i) != 0) continue;
        defer c.git_patch_free(patch);

        if (patch == null) continue;

        const delta = c.git_patch_get_delta(patch);

        // File header
        try writer.writeAll("<div class='ssdiff-file-header'>");
        try html.htmlEscape(writer, std.mem.span(delta.*.new_file.path));
        try writer.writeAll("</div>\n");

        try writer.writeAll("<table class='ssdiff'>\n");

        const num_hunks = c.git_patch_num_hunks(patch);

        for (0..num_hunks) |h| {
            var lines_in_hunk: usize = 0;
            var hunk: ?*const c.git_diff_hunk = null;

            if (c.git_patch_get_hunk(&hunk, &lines_in_hunk, patch, h) != 0) continue;

            // Hunk header
            try writer.writeAll("<tr class='ssdiff-hunk'>");
            try writer.writeAll("<td class='lineno'></td>");
            try writer.writeAll("<td class='hunk' colspan='3'>");

            if (hunk) |hk| {
                // The header is a fixed-size array, find the null terminator or use full length
                const header_bytes = &hk.*.header;
                var header_len: usize = 0;
                for (header_bytes) |byte| {
                    if (byte == 0) break;
                    header_len += 1;
                }
                const hunk_header = header_bytes[0..header_len];
                try html.htmlEscape(writer, hunk_header);
            } else {
                try writer.writeAll("@@");
            }

            try writer.writeAll("</td>");
            try writer.writeAll("</tr>\n");

            // Collect all lines for this hunk first
            var hunk_lines = std.ArrayList(DiffLine).empty;
            defer hunk_lines.deinit(std.heap.page_allocator);

            for (0..lines_in_hunk) |l| {
                var line: ?*const c.git_diff_line = null;
                if (c.git_patch_get_line_in_hunk(&line, patch, h, l) != 0) continue;

                if (line) |ln| {
                    const content = @as([*]const u8, @ptrCast(ln.*.content))[0..@intCast(ln.*.content_len)];
                    try hunk_lines.append(std.heap.page_allocator, .{
                        .origin = ln.*.origin,
                        .content = content,
                        .old_lineno = ln.*.old_lineno,
                        .new_lineno = ln.*.new_lineno,
                    });
                }
            }

            // Process lines, grouping consecutive deletions and additions
            var line_idx: usize = 0;
            while (line_idx < hunk_lines.items.len) {
                const line = hunk_lines.items[line_idx];

                switch (line.origin) {
                    ' ' => {
                        // Context line - appears on both sides with same content
                        try writer.writeAll("<tr>");

                        // Old side
                        try writer.writeAll("<td class='lineno'>");
                        if (line.old_lineno > 0) {
                            try writer.print("{d}", .{line.old_lineno});
                        }
                        try writer.writeAll("</td>");
                        try writer.writeAll("<td>");
                        try html.htmlEscape(writer, line.content);
                        try writer.writeAll("</td>");

                        // New side
                        try writer.writeAll("<td class='lineno'>");
                        if (line.new_lineno > 0) {
                            try writer.print("{d}", .{line.new_lineno});
                        }
                        try writer.writeAll("</td>");
                        try writer.writeAll("<td>");
                        try html.htmlEscape(writer, line.content);
                        try writer.writeAll("</td>");

                        try writer.writeAll("</tr>\n");
                        line_idx += 1;
                    },
                    '-' => {
                        // Collect consecutive deletions
                        const del_start = line_idx;
                        while (line_idx < hunk_lines.items.len and hunk_lines.items[line_idx].origin == '-') {
                            line_idx += 1;
                        }

                        // Collect consecutive additions that follow
                        const add_start = line_idx;
                        while (line_idx < hunk_lines.items.len and hunk_lines.items[line_idx].origin == '+') {
                            line_idx += 1;
                        }

                        const num_dels = add_start - del_start;
                        const num_adds = line_idx - add_start;
                        const max_lines = @max(num_dels, num_adds);

                        // Render the changes side by side
                        for (0..max_lines) |row| {
                            try writer.writeAll("<tr>");

                            // Old side (deletion)
                            if (row < num_dels) {
                                const del_line = hunk_lines.items[del_start + row];
                                try writer.writeAll("<td class='lineno'>");
                                if (del_line.old_lineno > 0) {
                                    try writer.print("{d}", .{del_line.old_lineno});
                                }
                                try writer.writeAll("</td>");
                                try writer.writeAll("<td class='del'>");
                                try html.htmlEscape(writer, del_line.content);
                                try writer.writeAll("</td>");
                            } else {
                                try writer.writeAll("<td class='lineno'></td>");
                                try writer.writeAll("<td></td>");
                            }

                            // New side (addition)
                            if (row < num_adds) {
                                const add_line = hunk_lines.items[add_start + row];
                                try writer.writeAll("<td class='lineno'>");
                                if (add_line.new_lineno > 0) {
                                    try writer.print("{d}", .{add_line.new_lineno});
                                }
                                try writer.writeAll("</td>");
                                try writer.writeAll("<td class='add'>");
                                try html.htmlEscape(writer, add_line.content);
                                try writer.writeAll("</td>");
                            } else {
                                try writer.writeAll("<td class='lineno'></td>");
                                try writer.writeAll("<td></td>");
                            }

                            try writer.writeAll("</tr>\n");
                        }
                    },
                    '+' => {
                        // Standalone addition (not preceded by deletion)
                        try writer.writeAll("<tr>");

                        // Old side (empty)
                        try writer.writeAll("<td class='lineno'></td>");
                        try writer.writeAll("<td></td>");

                        // New side (addition)
                        try writer.writeAll("<td class='lineno'>");
                        if (line.new_lineno > 0) {
                            try writer.print("{d}", .{line.new_lineno});
                        }
                        try writer.writeAll("</td>");
                        try writer.writeAll("<td class='add'>");
                        try html.htmlEscape(writer, line.content);
                        try writer.writeAll("</td>");

                        try writer.writeAll("</tr>\n");
                        line_idx += 1;
                    },
                    else => {
                        line_idx += 1;
                    },
                }
            }
        }

        try writer.writeAll("</table>\n");
    }

    try writer.writeAll("</div>\n");
}

const DiffLine = struct {
    origin: u8,
    content: []const u8,
    old_lineno: c_int,
    new_lineno: c_int,
};

fn displayDiffStat(diff_obj: *git.Diff, writer: anytype) !void {
    try writer.writeAll("<table class='diffstat-table'>\n");
    try writer.writeAll("<tr><th>File</th><th>Changes</th><th>Graph</th></tr>\n");

    const num_deltas = diff_obj.numDeltas();
    var max_changes: usize = 0;

    // First pass: collect statistics and find max changes
    var file_stats = std.ArrayList(FileStats).empty;
    defer file_stats.deinit(std.heap.page_allocator);

    for (0..num_deltas) |i| {
        var patch: ?*c.git_patch = null;
        if (c.git_patch_from_diff(&patch, diff_obj.diff, i) != 0) continue;
        defer c.git_patch_free(patch);

        if (patch == null) continue;

        var additions: usize = 0;
        var deletions: usize = 0;

        if (c.git_patch_line_stats(null, &additions, &deletions, patch) == 0) {
            const total = additions + deletions;
            if (total > max_changes) max_changes = total;

            const delta = diff_obj.getDelta(i).?;
            try file_stats.append(std.heap.page_allocator, .{
                .delta = delta,
                .additions = additions,
                .deletions = deletions,
            });
        }
    }

    // Second pass: render the table
    for (file_stats.items) |stat| {
        try writer.writeAll("<tr>");

        // File name
        try writer.writeAll("<td>");
        if (stat.delta.*.status == c.GIT_DELTA_RENAMED) {
            try html.htmlEscape(writer, std.mem.span(stat.delta.*.old_file.path));
            try writer.writeAll(" → ");
            try html.htmlEscape(writer, std.mem.span(stat.delta.*.new_file.path));
        } else {
            try html.htmlEscape(writer, std.mem.span(stat.delta.*.new_file.path));
        }
        try writer.writeAll("</td>");

        // Changes count
        try writer.writeAll("<td style='text-align: right'>");
        if (stat.additions > 0 and stat.deletions > 0) {
            try writer.print("+{d},-{d}", .{ stat.additions, stat.deletions });
        } else if (stat.additions > 0) {
            try writer.print("+{d}", .{stat.additions});
        } else if (stat.deletions > 0) {
            try writer.print("-{d}", .{stat.deletions});
        } else {
            try writer.writeAll("0");
        }
        try writer.writeAll("</td>");

        // Graph
        try writer.writeAll("<td>");
        const total = stat.additions + stat.deletions;
        if (total > 0 and max_changes > 0) {
            const graph_width = 40; // Max width of graph in chars
            const scaled_width = (total * graph_width) / max_changes;
            const add_width = (stat.additions * scaled_width) / total;
            const del_width = scaled_width - add_width;

            try writer.writeAll("<span class='diffstat-graph'>");
            if (add_width > 0) {
                try writer.writeAll("<span style='color: green'>");
                for (0..add_width) |_| try writer.writeAll("+");
                try writer.writeAll("</span>");
            }
            if (del_width > 0) {
                try writer.writeAll("<span style='color: red'>");
                for (0..del_width) |_| try writer.writeAll("-");
                try writer.writeAll("</span>");
            }
            try writer.writeAll("</span>");
        }
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
    }

    try writer.writeAll("</table>\n");
}

const FileStats = struct {
    delta: *const c.git_diff_delta,
    additions: usize,
    deletions: usize,
};

pub fn rawdiff(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    // Set content type for raw diff
    ctx.page.mimetype = "text/plain";

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("Unable to open repository.\n");
        return;
    };
    defer git_repo.close();

    // Get the first commit - either from ID or from branch/HEAD
    const commit1_oid = if (ctx.query.get("id")) |commit_id| blk: {
        // Parse commit ID
        break :blk try git.stringToOid(commit_id);
    } else blk: {
        // No ID specified, get latest commit from branch or HEAD
        const ref_name = ctx.query.get("h") orelse "HEAD";

        if (std.mem.eql(u8, ref_name, "HEAD")) {
            var head_ref = try git_repo.getHead();
            defer head_ref.free();

            const head_oid = head_ref.target() orelse return error.NoCommit;
            break :blk head_oid.*;
        } else {
            // Try to get the reference
            var ref = git_repo.getReference(ref_name) catch {
                // Try with refs/heads/ prefix
                const full_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_name}, @as(u8, 0));
                defer ctx.allocator.free(full_ref);

                var ref2 = git_repo.getReference(full_ref) catch {
                    return error.BranchNotFound;
                };
                defer ref2.free();

                const oid = ref2.target() orelse return error.NoCommit;
                break :blk oid.*;
            };
            defer ref.free();

            const oid = ref.target() orelse return error.NoCommit;
            break :blk oid.*;
        }
    };

    const id2 = ctx.query.get("id2") orelse return error.NoSecondCommit;
    const oid2 = try git.stringToOid(id2);

    // Get the commits
    var commit1 = try git_repo.lookupCommit(&commit1_oid);
    defer commit1.free();

    var commit2 = try git_repo.lookupCommit(&oid2);
    defer commit2.free();

    // Get trees
    var tree1 = try commit1.tree();
    defer tree1.free();

    var tree2 = try commit2.tree();
    defer tree2.free();

    // Create diff
    var diff_obj = try git.Diff.treeToTree(git_repo.repo, tree2.tree, tree1.tree, null);
    defer diff_obj.free();

    // Output raw diff
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

            if (line.*.origin != ' ' and line.*.origin != '\n') {
                self.writer.writeByte(line.*.origin) catch return -1;
            }

            const content = @as([*]const u8, @ptrCast(line.*.content))[0..@intCast(line.*.content_len)];
            self.writer.writeAll(content) catch return -1;

            if (!std.mem.endsWith(u8, content, "\n")) {
                self.writer.writeAll("\n") catch return -1;
            }

            return 0;
        }
    }{ .writer = writer };

    try diff_obj.print(c.GIT_DIFF_FORMAT_PATCH, @TypeOf(callback_data).printLine, @ptrCast(@constCast(&callback_data)));
}

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
        try writer.print("<a href='?cmd=diff&id={s}&id2={s}&dt=unified'>Unified</a> | ", .{ oid1_str, oid2_str });
    }

    if (std.mem.eql(u8, diff_type, "ssdiff")) {
        try writer.writeAll("<strong>Side-by-side</strong> | ");
    } else {
        try writer.print("<a href='?cmd=diff&id={s}&id2={s}&dt=ssdiff'>Side-by-side</a> | ", .{ oid1_str, oid2_str });
    }

    if (std.mem.eql(u8, diff_type, "stat")) {
        try writer.writeAll("<strong>Stat only</strong>");
    } else {
        try writer.print("<a href='?cmd=diff&id={s}&id2={s}&dt=stat'>Stat only</a>", .{ oid1_str, oid2_str });
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

            switch (line.*.origin) {
                '+' => self.writer.writeAll("<span class='add'>") catch return -1,
                '-' => self.writer.writeAll("<span class='del'>") catch return -1,
                '@' => self.writer.writeAll("<span class='hunk'>") catch return -1,
                else => {},
            }

            if (line.*.origin != ' ' and line.*.origin != '\n') {
                self.writer.writeByte(line.*.origin) catch return -1;
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

    try diff_obj.print(c.GIT_DIFF_FORMAT_PATCH, @TypeOf(callback_data).printLine, @ptrCast(@constCast(&callback_data)));

    try writer.writeAll("</pre>\n");
}

fn displaySideBySideDiff(diff_obj: *git.Diff, writer: anytype) !void {
    try writer.writeAll("<table class='ssdiff'>\n");
    try writer.writeAll("<tr><th colspan='2'>Old</th><th colspan='2'>New</th></tr>\n");

    const num_deltas = diff_obj.numDeltas();

    for (0..num_deltas) |i| {
        const delta = diff_obj.getDelta(i).?;

        try writer.writeAll("<tr class='ssdiff-file'><td colspan='4'>");
        try html.htmlEscape(writer, std.mem.span(delta.*.new_file.path));
        try writer.writeAll("</td></tr>\n");

        // TODO: Implement proper side-by-side diff rendering
        // For now, show a placeholder
        try writer.writeAll("<tr><td colspan='2'>Old content</td><td colspan='2'>New content</td></tr>\n");
    }

    try writer.writeAll("</table>\n");
}

fn displayDiffStat(diff_obj: *git.Diff, writer: anytype) !void {
    try writer.writeAll("<table class='diffstat-table'>\n");
    try writer.writeAll("<tr><th>File</th><th>Changes</th><th>Graph</th></tr>\n");

    const num_deltas = diff_obj.numDeltas();

    for (0..num_deltas) |i| {
        const delta = diff_obj.getDelta(i).?;

        try writer.writeAll("<tr>");

        // File name
        try writer.writeAll("<td>");
        if (delta.*.status == c.GIT_DELTA_RENAMED) {
            try html.htmlEscape(writer, std.mem.span(delta.*.old_file.path));
            try writer.writeAll(" → ");
            try html.htmlEscape(writer, std.mem.span(delta.*.new_file.path));
        } else {
            try html.htmlEscape(writer, std.mem.span(delta.*.new_file.path));
        }
        try writer.writeAll("</td>");

        // Changes count
        try writer.writeAll("<td>");
        // TODO: Get per-file statistics
        try writer.writeAll("N/A");
        try writer.writeAll("</td>");

        // Graph
        try writer.writeAll("<td>");
        try writer.writeAll("<span class='diffstat-graph'>");
        // TODO: Draw change graph
        try writer.writeAll("+++---");
        try writer.writeAll("</span>");
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
    }

    try writer.writeAll("</table>\n");
}

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

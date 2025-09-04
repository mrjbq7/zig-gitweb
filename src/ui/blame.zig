const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = git.c;

pub fn blame(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse {
        try writer.writeAll("<div class='error'>\n");
        try writer.writeAll("<p>No repository specified.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    const path = ctx.query.get("path") orelse {
        try writer.writeAll("<div class='error'>\n");
        try writer.writeAll("<p>No file path specified.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };

    try writer.writeAll("<div class='blame'>\n");

    // Show breadcrumb
    try shared.writeBreadcrumb(ctx, writer, path);

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Get the commit - try id first, then h, then default to HEAD
    var commit_oid: git.c.git_oid = undefined;
    if (ctx.query.get("id")) |id_str| {
        // Try to parse as OID
        if (git.c.git_oid_fromstr(&commit_oid, id_str.ptr) != 0) {
            // If parsing fails, try as ref
            const ref_name = id_str;
            var ref = git_repo.getReference(ref_name) catch git_repo.getHead() catch {
                try writer.writeAll("<p>Unable to find reference.</p>\n");
                try writer.writeAll("</div>\n");
                return;
            };
            defer ref.free();

            // Resolve symbolic reference to commit
            var commit_obj = ref.peel(git.c.GIT_OBJECT_COMMIT) catch {
                try writer.writeAll("<p>Unable to resolve reference to commit.</p>\n");
                try writer.writeAll("</div>\n");
                return;
            };
            defer commit_obj.free();

            commit_oid = c.git_object_id(@ptrCast(commit_obj.obj)).*;
        }
    } else {
        // Try branch/ref name
        const ref_name = ctx.query.get("h") orelse "HEAD";
        var ref = git_repo.getReference(ref_name) catch git_repo.getHead() catch {
            try writer.writeAll("<p>Unable to find reference.</p>\n");
            try writer.writeAll("</div>\n");
            return;
        };
        defer ref.free();

        // Resolve symbolic reference to commit
        var commit_obj = ref.peel(git.c.GIT_OBJECT_COMMIT) catch {
            try writer.writeAll("<p>Unable to resolve reference to commit.</p>\n");
            try writer.writeAll("</div>\n");
            return;
        };
        defer commit_obj.free();

        commit_oid = c.git_object_id(@ptrCast(commit_obj.obj)).*;
    }

    // Create blame options with performance optimizations
    var blame_opts = std.mem.zeroes(c.git_blame_options);
    _ = c.git_blame_options_init(&blame_opts, c.GIT_BLAME_OPTIONS_VERSION);

    // Performance optimizations:
    // 1. Set the newest_commit to limit history traversal
    blame_opts.newest_commit = commit_oid;

    // 2. Use first parent only for merge commits (much faster)
    blame_opts.flags |= c.GIT_BLAME_FIRST_PARENT;

    // 3. Don't track copies - this is expensive
    blame_opts.flags = c.GIT_BLAME_NORMAL | c.GIT_BLAME_FIRST_PARENT;

    // 4. Set minimum match characters to avoid tiny matches
    blame_opts.min_match_characters = 20;

    // Generate blame
    var blame_obj: ?*c.git_blame = null;
    const c_path = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(c_path);

    const blame_result = c.git_blame_file(&blame_obj, @ptrCast(git_repo.repo), c_path, &blame_opts);
    if (blame_result != 0) {
        try writer.writeAll("<p>Unable to generate blame for this file.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    }
    defer c.git_blame_free(blame_obj);

    // Get file content for display
    var commit = try git_repo.lookupCommit(&commit_oid);
    defer commit.free();

    var tree = try commit.tree();
    defer tree.free();

    // Navigate to the blob
    var blob_entry: ?*const c.git_tree_entry = null;
    var current_tree = tree;
    var path_parts = std.mem.tokenizeAny(u8, path, "/");

    while (path_parts.next()) |part| {
        const entry = current_tree.entryByName(part) orelse {
            try writer.writeAll("<p>File not found.</p>\n");
            try writer.writeAll("</div>\n");
            if (&current_tree != &tree) current_tree.free();
            return;
        };

        if (path_parts.peek() == null) {
            blob_entry = @ptrCast(entry);
            break;
        } else {
            if (c.git_tree_entry_type(@ptrCast(entry)) != c.GIT_OBJECT_TREE) {
                try writer.writeAll("<p>Invalid path.</p>\n");
                try writer.writeAll("</div>\n");
                if (&current_tree != &tree) current_tree.free();
                return;
            }

            const tree_oid = c.git_tree_entry_id(@ptrCast(entry));
            const new_tree = try git_repo.lookupTree(@constCast(tree_oid));
            if (&current_tree != &tree) {
                current_tree.free();
            }
            current_tree = new_tree;
        }
    }

    defer {
        if (&current_tree != &tree) {
            current_tree.free();
        }
    }

    if (blob_entry == null) {
        try writer.writeAll("<p>File not found.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    }

    // Get the blob content
    const blob_oid = c.git_tree_entry_id(blob_entry.?);
    var blob = try git_repo.lookupBlob(@constCast(blob_oid));
    defer blob.free();

    const content = blob.content();

    // Display blame table
    try writer.writeAll("<table class='blame'>\n");

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 1;
    var prev_hunk: ?*const c.git_blame_hunk = null;

    // Pre-allocate buffer for OID strings
    var oid_buf: [41]u8 = undefined;

    while (lines.next()) |line| {
        const hunk = c.git_blame_get_hunk_byline(blame_obj, line_num);

        try writer.writeAll("<tr>");

        if (hunk != null) {
            // Check if we're in the same hunk (faster than comparing OIDs)
            const is_same_hunk = (prev_hunk == hunk);

            if (!is_same_hunk) {
                // Commit hash - convert OID once per hunk
                try writer.writeAll("<td class='blame-commit'>");
                _ = c.git_oid_tostr(&oid_buf, oid_buf.len, &hunk.*.final_commit_id);
                try shared.writeCommitLink(ctx, writer, &oid_buf, oid_buf[0..7]);
                try writer.writeAll("</td>");

                // Author
                try writer.writeAll("<td class='blame-author'>");
                const sig = hunk.*.final_signature;
                if (sig != null) {
                    const author_name = std.mem.span(sig.*.name);
                    try html.htmlEscape(writer, parsing.truncateString(author_name, 20));
                }
                try writer.writeAll("</td>");

                // Date
                try writer.writeAll("<td class='blame-date'>");
                if (sig != null) {
                    try shared.formatAge(writer, @intCast(sig.*.when.time));
                }
                try writer.writeAll("</td>");

                prev_hunk = hunk;
            } else {
                // Same hunk, show continuation
                try writer.writeAll("<td class='blame-commit' style='border-top: none;'></td>");
                try writer.writeAll("<td class='blame-author' style='border-top: none;'></td>");
                try writer.writeAll("<td class='blame-date' style='border-top: none;'></td>");
            }
        } else {
            try writer.writeAll("<td>-</td><td>-</td><td>-</td>");
        }

        // Line number
        try writer.print("<td class='linenumber'><a href='#L{d}' id='L{d}'>{d}</a></td>", .{ line_num, line_num, line_num });

        // Code
        try writer.writeAll("<td class='code'><pre>");
        try html.htmlEscape(writer, line);
        try writer.writeAll("</pre></td>");

        try writer.writeAll("</tr>\n");
        line_num += 1;
    }

    try writer.writeAll("</table>\n");

    // Add CSS for blame view
    try writer.writeAll(
        \\<style>
        \\table.blame { width: 100%; border-collapse: collapse; }
        \\table.blame td { padding: 2px 5px; vertical-align: top; }
        \\table.blame td.blame-commit { width: 80px; font-family: monospace; }
        \\table.blame td.blame-author { width: 150px; }
        \\table.blame td.blame-date { width: 100px; }
        \\table.blame td.linenumber { width: 50px; text-align: right; color: #666; }
        \\table.blame td.code { white-space: pre-wrap; word-wrap: break-word; }
        \\table.blame td.code pre { margin: 0; }
        \\table.blame tr:hover { background: #f5f5f5; }
        \\</style>
        \\
    );

    try writer.writeAll("</div>\n");
}

const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");
const sharedUtils = @import("../shared.zig");

const c = git.c;

pub fn blob(ctx: *gitweb.Context, writer: anytype) !void {
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

    try writer.writeAll("<div class='blob'>\n");

    // Show breadcrumb
    try shared.writeBreadcrumb(ctx, writer, path);

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Get the commit - try id first, then h, then default to HEAD
    var commit = blk: {
        if (ctx.query.get("id")) |id_str| {
            // Try to parse as OID
            var oid: git.c.git_oid = undefined;
            if (git.c.git_oid_fromstr(&oid, id_str.ptr) == 0) {
                break :blk try git_repo.lookupCommit(&oid);
            }
        }

        // Try branch/ref name
        const ref_name = ctx.query.get("h") orelse "HEAD";

        // Get the reference
        var ref = git_repo.getReference(ref_name) catch git_repo.getHead() catch {
            try writer.writeAll("<p>Unable to find reference.</p>\n");
            try writer.writeAll("</div>\n");
            return;
        };
        defer ref.free();

        // Resolve the reference to a commit
        var commit_obj = ref.peel(git.c.GIT_OBJECT_COMMIT) catch {
            try writer.writeAll("<p>Unable to resolve reference to commit.</p>\n");
            try writer.writeAll("</div>\n");
            return;
        };
        defer commit_obj.free();

        // Cast the object to a commit
        const commit_ptr = @as(*git.c.git_commit, @ptrCast(commit_obj.obj));
        break :blk git.Commit{ .commit = commit_ptr };
    };
    defer commit.free();

    // Show commit info if viewing at a specific commit
    if (ctx.query.get("id")) |_| {
        const commit_oid_str = try git.oidToString(commit.id());
        const commit_time = commit.time();
        const commit_summary = commit.summary();
        const author = commit.author();

        try writer.writeAll("<div class='blob-commit-info'>");
        try writer.print("Viewing at commit <a href='?r={s}&cmd=commit&id={s}'>{s}</a>", .{ repo.name, commit_oid_str, commit_oid_str[0..7] });
        try writer.writeAll(" — ");
        try html.htmlEscape(writer, commit_summary);
        try writer.writeAll(" (");
        try html.htmlEscape(writer, std.mem.span(author.name));
        try writer.writeAll(", ");
        try shared.formatAge(writer, commit_time);
        try writer.writeAll(")</div>\n");
    }

    // Get the tree
    var tree = try commit.tree();
    defer tree.free();

    // Navigate to the blob
    var path_parts = std.mem.tokenizeAny(u8, path, "/");
    var current_tree = tree;
    var blob_entry: ?*const c.git_tree_entry = null;

    while (path_parts.next()) |part| {
        const entry = current_tree.entryByName(part) orelse {
            try writer.writeAll("<p>File not found.</p>\n");
            try writer.writeAll("</div>\n");
            if (&current_tree != &tree) current_tree.free();
            return;
        };

        if (path_parts.peek() == null) {
            // This is the final part - should be a blob
            if (c.git_tree_entry_type(@ptrCast(entry)) != c.GIT_OBJECT_BLOB) {
                try writer.writeAll("<p>Not a file.</p>\n");
                try writer.writeAll("</div>\n");
                if (&current_tree != &tree) current_tree.free();
                return;
            }
            blob_entry = @ptrCast(entry);
            break;
        } else {
            // Navigate deeper
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

    // Get the blob
    const blob_oid = c.git_tree_entry_id(blob_entry.?);
    var blob_obj = try git_repo.lookupBlob(@constCast(blob_oid));
    defer blob_obj.free();

    // Display blob info
    const size = blob_obj.size();
    const is_binary = blob_obj.isBinary();

    try writer.writeAll("<div class='blob-info'>");
    try writer.print("File size: ", .{});
    try parsing.formatFileSize(size, writer);
    if (is_binary) {
        try writer.writeAll(" (binary file)");
    }
    try writer.writeAll("</div>\n");

    // Display content
    const content = blob_obj.content();

    // Check if hex dump mode is requested
    const show_hex = if (ctx.query.get("hex")) |h| std.mem.eql(u8, h, "1") else false;

    if (show_hex) {
        try displayHexDump(ctx, path, blob_oid, content, writer);
    } else if (is_binary or sharedUtils.isBinaryContent(content)) {
        try displayBinaryFile(ctx, path, blob_oid, size, writer);
    } else {
        try displayTextFile(ctx, path, content, writer);
    }

    try writer.writeAll("</div>\n");
}

fn displayTextFile(ctx: *gitweb.Context, path: []const u8, content: []const u8, writer: anytype) !void {

    // Add download/raw and blame links
    try writer.writeAll("<div class='blob-actions'>");

    // View Raw link
    try writer.writeAll("<a class='btn' href='?");
    if (ctx.repo) |r| {
        try writer.print("r={s}&", .{r.name});
    }
    try writer.writeAll("cmd=plain&path=");
    try html.urlEncodePath(writer, path);
    try writer.writeAll("'>View Raw</a>");

    // History link
    try writer.writeAll("<a class='btn' href='?");
    if (ctx.repo) |r| {
        try writer.print("r={s}&", .{r.name});
    }
    try writer.writeAll("cmd=log");
    // Preserve commit ID or branch
    if (ctx.query.get("id")) |id| {
        try writer.print("&id={s}", .{id});
    } else if (ctx.query.get("h")) |h| {
        try writer.print("&h={s}", .{h});
    }
    try writer.writeAll("&path=");
    try html.urlEncodePath(writer, path);
    try writer.writeAll("'>History</a>");

    // Blame link
    try writer.writeAll("<a class='btn' href='?");
    if (ctx.repo) |r| {
        try writer.print("r={s}&", .{r.name});
    }
    try writer.writeAll("cmd=blame");
    // Preserve commit ID or branch
    if (ctx.query.get("id")) |id| {
        try writer.print("&id={s}", .{id});
    } else if (ctx.query.get("h")) |h| {
        try writer.print("&h={s}", .{h});
    }
    try writer.writeAll("&path=");
    try html.urlEncodePath(writer, path);
    try writer.writeAll("'>Blame</a>");

    try writer.writeAll("</div>\n");

    // Check if content is too large
    if (content.len > 1024 * 1024) { // 1MB limit for syntax highlighting
        try writer.writeAll("<pre class='blob no-linenumbers'>");
        try html.htmlEscape(writer, content);
        try writer.writeAll("</pre>\n");
        return;
    }

    // Display with line numbers
    try writer.print("<pre class='blob' data-filename='{s}'>", .{path});

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 1;

    try writer.writeAll("<table class='blob-content'>");
    while (lines.next()) |line| {
        try writer.writeAll("<tr>");

        // Line number
        try writer.print("<td class='linenumber' id='L{d}'><a href='#L{d}'>{d}</a></td>", .{ line_num, line_num, line_num });

        // Line content
        try writer.writeAll("<td class='code'>");
        try html.htmlEscape(writer, line);
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
        line_num += 1;
    }
    try writer.writeAll("</table>");

    try writer.writeAll("</pre>\n");
}

fn displayBinaryFile(ctx: *gitweb.Context, path: []const u8, blob_oid: *const c.git_oid, size: u64, writer: anytype) !void {
    _ = blob_oid;
    const mime_type = sharedUtils.getMimeType(path);

    try writer.writeAll("<div class='binary-file'>\n");

    // Add action links for binary files
    try writer.writeAll("<div class='blob-actions'>");

    // Download link
    try writer.writeAll("<a class='btn' href='?");
    if (ctx.repo) |r| {
        try writer.print("r={s}&", .{r.name});
    }
    try writer.writeAll("cmd=plain&path=");
    try html.urlEncodePath(writer, path);
    try writer.print("' download>Download ({s}, ", .{mime_type});
    try parsing.formatFileSize(size, writer);
    try writer.writeAll(")</a>");

    // History link
    try writer.writeAll("<a class='btn' href='?");
    if (ctx.repo) |r| {
        try writer.print("r={s}&", .{r.name});
    }
    try writer.writeAll("cmd=log");
    if (ctx.query.get("id")) |id| {
        try writer.print("&id={s}", .{id});
    } else if (ctx.query.get("h")) |h| {
        try writer.print("&h={s}", .{h});
    }
    try writer.writeAll("&path=");
    try html.urlEncodePath(writer, path);
    try writer.writeAll("'>History</a>");

    // Hex dump link
    try writer.writeAll("<a class='btn' href='?");
    if (ctx.repo) |r| {
        try writer.print("r={s}&", .{r.name});
    }
    try writer.writeAll("cmd=blob");
    if (ctx.query.get("h")) |h| {
        try writer.print("&h={s}", .{h});
    }
    try writer.writeAll("&path=");
    try html.urlEncodePath(writer, path);
    try writer.writeAll("&hex=1'>Hex Dump</a>");

    try writer.writeAll("</div>\n");

    if (std.mem.startsWith(u8, mime_type, "image/")) {
        // Display image
        try writer.writeAll("<img src='?");
        if (ctx.repo) |r| {
            try writer.print("r={s}&", .{r.name});
        }
        try writer.writeAll("cmd=plain&path=");
        try html.urlEncodePath(writer, path);
        try writer.print("' alt='{s}' style='max-width: 100%;' />\n", .{std.fs.path.basename(path)});
    } else {
        // Show message for non-image binary files
        try writer.writeAll("<p>Binary file cannot be displayed directly.</p>\n");
    }

    try writer.writeAll("</div>\n");
}

fn displayHexDump(ctx: *gitweb.Context, path: []const u8, blob_oid: *const c.git_oid, content: []const u8, writer: anytype) !void {
    const size = content.len;
    const mime_type = sharedUtils.getMimeType(path);

    // Add action links
    try writer.writeAll("<div class='blob-actions'>");

    // Download link
    try writer.writeAll("<a class='btn' href='?");
    if (ctx.repo) |r| {
        try writer.print("r={s}&", .{r.name});
    }
    try writer.writeAll("cmd=plain&path=");
    try html.urlEncodePath(writer, path);
    try writer.print("' download>Download ({s}, ", .{mime_type});
    try parsing.formatFileSize(size, writer);
    try writer.writeAll(")</a>");

    // Normal view link
    try writer.writeAll("<a class='btn' href='?");
    if (ctx.repo) |r| {
        try writer.print("r={s}&", .{r.name});
    }
    try writer.writeAll("cmd=blob");
    if (ctx.query.get("h")) |h| {
        try writer.print("&h={s}", .{h});
    }
    try writer.writeAll("&path=");
    try html.urlEncodePath(writer, path);
    try writer.writeAll("'>Normal View</a>");

    try writer.writeAll("</div>\n");

    // Display blob SHA
    const oid_str = try git.oidToString(blob_oid);
    try writer.print("<div class='blob-info'>blob: {s} (plain)</div>\n", .{oid_str});

    // Hex dump table
    try writer.writeAll("<div class='hex-dump'>\n");
    try writer.writeAll("<table class='hex-dump-table'>\n");
    try writer.writeAll("<thead><tr><th>offset</th><th>hex dump</th><th>ascii</th></tr></thead>\n");
    try writer.writeAll("<tbody>\n");

    var offset: usize = 0;
    const bytes_per_line = 16;

    while (offset < content.len) {
        const end = @min(offset + bytes_per_line, content.len);
        const line = content[offset..end];

        try writer.writeAll("<tr>");

        // Offset column
        try writer.print("<td class='offset'>{x:0>8}</td>", .{offset});

        // Hex dump column
        try writer.writeAll("<td class='hex'>");
        for (line, 0..) |byte, i| {
            if (i == 8) try writer.writeAll(" "); // Extra space in middle
            try writer.print(" {x:0>2}", .{byte});
        }
        // Pad if line is short
        if (line.len < bytes_per_line) {
            const padding = bytes_per_line - line.len;
            for (0..padding) |_| {
                try writer.writeAll("   ");
            }
            if (line.len <= 8) try writer.writeAll(" "); // Extra space if first half is incomplete
        }
        try writer.writeAll("</td>");

        // ASCII column
        try writer.writeAll("<td class='ascii'>");
        for (line) |byte| {
            if (std.ascii.isPrint(byte) and byte != '<' and byte != '>' and byte != '&') {
                try writer.writeByte(byte);
            } else {
                try writer.writeAll(".");
            }
        }
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
        offset += bytes_per_line;
    }

    try writer.writeAll("</tbody>\n");
    try writer.writeAll("</table>\n");
    try writer.writeAll("</div>\n");
}

const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");
const sharedUtils = @import("../shared.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn blob(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    const path = ctx.query.get("path") orelse return error.NoPath;

    try writer.writeAll("<div class='blob'>\n");

    // Show breadcrumb
    try shared.writeBreadcrumb(ctx, writer, path);

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Get the reference
    const ref_name = ctx.query.get("h") orelse "HEAD";
    var ref = git_repo.getReference(ref_name) catch git_repo.getHead() catch {
        try writer.writeAll("<p>Unable to find reference.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer ref.free();

    // Get the commit
    const target = ref.target() orelse {
        try writer.writeAll("<p>Invalid reference target.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };

    var commit = try git_repo.lookupCommit(target);
    defer commit.free();

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

    if (is_binary or sharedUtils.isBinaryContent(content)) {
        try displayBinaryFile(ctx, path, size, writer);
    } else {
        try displayTextFile(ctx, path, content, writer);
    }

    try writer.writeAll("</div>\n");
}

fn displayTextFile(ctx: *gitweb.Context, path: []const u8, content: []const u8, writer: anytype) !void {
    _ = ctx;

    // Add download/raw link
    try writer.print("<div class='blob-actions'><a href='?cmd=plain&path={s}'>View Raw</a></div>\n", .{path});

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

fn displayBinaryFile(ctx: *gitweb.Context, path: []const u8, size: u64, writer: anytype) !void {
    _ = ctx;

    const mime_type = sharedUtils.getMimeType(path);

    try writer.writeAll("<div class='binary-file'>\n");

    if (std.mem.startsWith(u8, mime_type, "image/")) {
        // Display image
        try writer.print("<img src='?cmd=plain&path={s}' alt='{s}' style='max-width: 100%;' />\n", .{ path, std.fs.path.basename(path) });
    } else {
        // Show download link
        try writer.writeAll("<p>Binary file cannot be displayed.</p>\n");
        try writer.print("<a href='?cmd=plain&path={s}' download>Download ({s}, ", .{ path, mime_type });
        try parsing.formatFileSize(size, writer);
        try writer.writeAll(")</a>\n");
    }

    try writer.writeAll("</div>\n");
}

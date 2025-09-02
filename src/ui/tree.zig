const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn tree(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='tree'>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Get the tree to display
    const path = ctx.query.get("path") orelse "";

    // Show breadcrumb if we have a path
    if (path.len > 0) {
        try shared.writeBreadcrumb(ctx, writer, path);
    }

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
        var ref = git_repo.getReference(ref_name) catch git_repo.getHead() catch |err| {
            std.debug.print("tree: Failed to get reference '{s}': {}\n", .{ ref_name, err });
            try writer.writeAll("<p>Unable to find reference.</p>\n");
            try writer.writeAll("</div>\n");
            return;
        };
        defer ref.free();

        // Resolve the reference to a commit
        // If it's a symbolic ref (like HEAD), peel it to a commit
        var commit_obj = ref.peel(git.c.GIT_OBJECT_COMMIT) catch |err| {
            std.debug.print("tree: Failed to peel reference to commit: {}\n", .{err});
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

    // Get the tree
    var root_tree = try commit.tree();
    defer root_tree.free();

    // Navigate to subpath if specified
    var current_tree = root_tree;
    if (path.len > 0) {
        var path_parts = std.mem.tokenizeAny(u8, path, "/");
        while (path_parts.next()) |part| {
            const entry = current_tree.entryByName(part) orelse {
                try writer.writeAll("<p>Path not found.</p>\n");
                try writer.writeAll("</div>\n");
                return;
            };

            if (c.git_tree_entry_type(@ptrCast(entry)) != c.GIT_OBJECT_TREE) {
                // This is a blob, redirect to blob view
                try writer.print("<script>window.location='?cmd=blob&path={s}';</script>", .{path});
                try writer.writeAll("</div>\n");
                return;
            }

            const tree_oid = c.git_tree_entry_id(@ptrCast(entry));
            const new_tree = try git_repo.lookupTree(@constCast(tree_oid));
            if (&current_tree != &root_tree) {
                current_tree.free();
            }
            current_tree = new_tree;
        }
    }
    defer {
        if (&current_tree != &root_tree) {
            current_tree.free();
        }
    }

    // Display tree entries
    try displayTreeEntries(ctx, &git_repo, &current_tree, path, writer);

    try writer.writeAll("</div>\n");
}

fn displayTreeEntries(ctx: *gitweb.Context, repo: *git.Repository, tree_obj: *git.Tree, base_path: []const u8, writer: anytype) !void {
    const headers = [_][]const u8{ "Mode", "Name", "Size", "Age" };
    try html.writeTableHeader(writer, &headers);

    // Parent directory link
    if (base_path.len > 0) {
        try html.writeTableRow(writer, null);
        try writer.writeAll("<td>d---------</td>");
        try writer.writeAll("<td colspan='3'><a href='?");
        if (ctx.repo) |r| {
            try writer.print("r={s}&", .{r.name});
        }
        try writer.writeAll("cmd=tree");

        const last_slash = std.mem.lastIndexOf(u8, base_path, "/");
        if (last_slash) |pos| {
            if (pos > 0) {
                try writer.print("&path={s}", .{base_path[0..pos]});
            }
        }
        try writer.writeAll("'>..</a></td>");
        try writer.writeAll("</tr>\n");
    }

    const count = tree_obj.entryCount();

    // Collect and sort entries (directories first, then files)
    var entries = try ctx.allocator.alloc(*const c.git_tree_entry, count);
    defer ctx.allocator.free(entries);

    for (0..count) |i| {
        entries[i] = @ptrCast(tree_obj.entryByIndex(i).?);
    }

    // Sort: directories first, then alphabetically
    std.sort.pdq(*const c.git_tree_entry, entries, {}, struct {
        fn lessThan(_: void, a: *const c.git_tree_entry, b: *const c.git_tree_entry) bool {
            const a_type = c.git_tree_entry_type(@as(?*const c.git_tree_entry, a));
            const b_type = c.git_tree_entry_type(@as(?*const c.git_tree_entry, b));

            if (a_type == c.GIT_OBJECT_TREE and b_type != c.GIT_OBJECT_TREE) {
                return true;
            }
            if (a_type != c.GIT_OBJECT_TREE and b_type == c.GIT_OBJECT_TREE) {
                return false;
            }

            const a_name = std.mem.span(c.git_tree_entry_name(@as(?*const c.git_tree_entry, a)));
            const b_name = std.mem.span(c.git_tree_entry_name(@as(?*const c.git_tree_entry, b)));
            return std.mem.lessThan(u8, a_name, b_name);
        }
    }.lessThan);

    // Display entries
    for (entries) |entry| {
        const entry_name = std.mem.span(c.git_tree_entry_name(@as(?*const c.git_tree_entry, entry)));
        const entry_type = c.git_tree_entry_type(@as(?*const c.git_tree_entry, entry));
        const entry_mode = c.git_tree_entry_filemode(@as(?*const c.git_tree_entry, entry));
        const entry_oid = c.git_tree_entry_id(@as(?*const c.git_tree_entry, entry));

        try html.writeTableRow(writer, null);

        // Mode
        try writer.writeAll("<td>");
        try writer.writeAll(git.getFileMode(entry_mode));
        try writer.writeAll("</td>");

        // Name
        try writer.writeAll("<td>");
        const full_path = if (base_path.len > 0)
            try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ base_path, entry_name })
        else
            entry_name;
        defer {
            if (base_path.len > 0) ctx.allocator.free(full_path);
        }

        if (entry_type == c.GIT_OBJECT_TREE) {
            try writer.writeAll("<a href='?");
            if (ctx.repo) |r| {
                try writer.print("r={s}&", .{r.name});
            }
            try writer.print("cmd=tree&path={s}'>{s}/</a>", .{ full_path, entry_name });
        } else {
            try writer.writeAll("<a href='?");
            if (ctx.repo) |r| {
                try writer.print("r={s}&", .{r.name});
            }
            try writer.print("cmd=blob&path={s}'>{s}</a>", .{ full_path, entry_name });
        }
        try writer.writeAll("</td>");

        // Size
        try writer.writeAll("<td>");
        if (entry_type == c.GIT_OBJECT_BLOB) {
            var blob = repo.lookupBlob(@constCast(entry_oid)) catch {
                try writer.writeAll("-");
                try writer.writeAll("</td>");
                try writer.writeAll("<td>-</td>");
                try writer.writeAll("</tr>\n");
                continue;
            };
            defer blob.free();

            const size = blob.size();
            try parsing.formatFileSize(size, writer);
        } else {
            try writer.writeAll("-");
        }
        try writer.writeAll("</td>");

        // Age (last commit for this file)
        try writer.writeAll("<td class='age'>");
        // TODO: Get last commit for this path
        try writer.writeAll("-");
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
    }

    try html.writeTableFooter(writer);
}

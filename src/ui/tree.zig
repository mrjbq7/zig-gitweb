const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = git.c;

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
                const commit_obj = git_repo.lookupCommit(&oid) catch {
                    try writer.writeAll("<p>Commit not found.</p>\n");
                    try writer.writeAll("</div>\n");
                    return;
                };
                break :blk commit_obj;
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
    const headers = [_][]const u8{ "Mode", "Name", "Size", "Age", "Last Commit", "" };
    try html.writeTableHeader(writer, &headers);

    // Parent directory link
    if (base_path.len > 0) {
        try html.writeTableRow(writer, null);
        try writer.writeAll("<td class='mode'>d---------</td>");
        try writer.writeAll("<td colspan='5'><a href='?");
        if (ctx.repo) |r| {
            try writer.print("r={s}&", .{r.name});
        }
        try writer.writeAll("cmd=tree");

        // Preserve commit ID or branch
        if (ctx.query.get("id")) |id| {
            try writer.print("&id={s}", .{id});
        } else if (ctx.query.get("h")) |branch| {
            try writer.print("&h={s}", .{branch});
        }

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
        try writer.writeAll("<td class='mode'>");
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
            try writer.writeAll("cmd=tree");
            // Preserve commit ID or branch
            if (ctx.query.get("id")) |id| {
                try writer.print("&id={s}", .{id});
            } else if (ctx.query.get("h")) |branch| {
                try writer.print("&h={s}", .{branch});
            }
            try writer.print("&path={s}'>{s}/</a>", .{ full_path, entry_name });
        } else {
            try writer.writeAll("<a href='?");
            if (ctx.repo) |r| {
                try writer.print("r={s}&", .{r.name});
            }
            try writer.writeAll("cmd=blob");
            // Preserve commit ID or branch
            if (ctx.query.get("id")) |id| {
                try writer.print("&id={s}", .{id});
            } else if (ctx.query.get("h")) |branch| {
                try writer.print("&h={s}", .{branch});
            }
            try writer.print("&path={s}'>{s}</a>", .{ full_path, entry_name });
        }
        try writer.writeAll("</td>");

        // Size
        try writer.writeAll("<td>");
        if (entry_type == c.GIT_OBJECT_BLOB) {
            var blob = repo.lookupBlob(@constCast(entry_oid)) catch {
                try writer.writeAll("-");
                try writer.writeAll("</td>");
                try writer.writeAll("<td class='age'>-</td>");
                try writer.writeAll("<td>-</td>");
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

        // Get the last commit for this path
        const last_commit_info = getLastCommitForPath(repo, full_path, ctx.allocator) catch blk: {
            // If we can't get commit info, show placeholders
            try writer.writeAll("<td class='age'>-</td>");
            try writer.writeAll("<td class='last-commit'>-</td>");
            break :blk null;
        };

        if (last_commit_info) |info| {
            defer ctx.allocator.free(info.message);
            
            // Age column
            try writer.writeAll("<td class='age'>");
            try shared.formatAge(writer, info.timestamp);
            try writer.writeAll("</td>");

            // Last commit message
            try writer.writeAll("<td class='last-commit'>");
            // Truncate to first line and limit length
            const first_line_end = std.mem.indexOfScalar(u8, info.message, '\n') orelse info.message.len;
            const summary = info.message[0..@min(first_line_end, 50)];
            try html.htmlEscape(writer, summary);
            if (first_line_end > 50) {
                try writer.writeAll("...");
            }
            try writer.writeAll("</td>");
        }

        // Log link
        try writer.writeAll("<td>");
        try writer.writeAll("<a href='?");
        if (ctx.repo) |r| {
            try writer.print("r={s}&", .{r.name});
        }
        try writer.writeAll("cmd=log");
        // Preserve commit ID or branch
        if (ctx.query.get("id")) |id| {
            try writer.print("&id={s}", .{id});
        } else if (ctx.query.get("h")) |branch| {
            try writer.print("&h={s}", .{branch});
        }
        try writer.print("&path={s}'>log</a>", .{full_path});
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
    }

    try html.writeTableFooter(writer);
}

const CommitInfo = struct {
    message: []u8,
    timestamp: i64,
};

fn getLastCommitForPath(repo: *git.Repository, path: []const u8, allocator: std.mem.Allocator) !CommitInfo {
    // Create a revwalk
    var walk = try repo.revwalk();
    defer walk.free();
    
    try walk.pushHead();
    walk.setSorting(git.c.GIT_SORT_TIME);
    
    // Walk through commits looking for one that touches this path
    while (walk.next()) |oid| {
        var commit = repo.lookupCommit(&oid) catch continue;
        defer commit.free();
        
        var commit_tree = commit.tree() catch continue;
        defer commit_tree.free();
        
        // Check if this commit's tree contains changes to our path
        // For the first parent (or no parents), check if path exists
        const parent_count = commit.parentCount();
        
        if (parent_count == 0) {
            // Initial commit - check if path exists in tree
            if (pathExistsInTree(&commit_tree, path)) {
                return CommitInfo{
                    .message = try allocator.dupe(u8, commit.summary()),
                    .timestamp = commit.time(),
                };
            }
        } else {
            // Check diff with first parent
            var parent = commit.parent(0) catch continue;
            defer parent.free();
            
            var parent_tree = parent.tree() catch continue;
            defer parent_tree.free();
            
            // Create diff
            var diff = git.Diff.treeToTree(@ptrCast(repo.repo), @ptrCast(parent_tree.tree), @ptrCast(commit_tree.tree), null) catch continue;
            defer diff.free();
            
            // Check if our path is in the diff
            const num_deltas = diff.numDeltas();
            for (0..num_deltas) |delta_idx| {
                const delta = diff.getDelta(delta_idx) orelse continue;
                
                // Check both old and new paths
                const old_path = std.mem.span(delta.old_file.path);
                const new_path = std.mem.span(delta.new_file.path);
                
                if (std.mem.eql(u8, old_path, path) or std.mem.eql(u8, new_path, path)) {
                    // This commit touched our path
                    return CommitInfo{
                        .message = try allocator.dupe(u8, commit.summary()),
                        .timestamp = commit.time(),
                    };
                }
            }
        }
    }
    
    return error.PathNotFound;
}

fn pathExistsInTree(tree_obj: *git.Tree, path: []const u8) bool {
    // Split path into components and traverse tree
    var path_parts = std.mem.tokenizeAny(u8, path, "/");
    var current_tree = tree_obj;
    var temp_tree: ?git.Tree = null;
    defer if (temp_tree) |*t| t.free();
    
    while (path_parts.next()) |part| {
        const entry = current_tree.entryByName(part) orelse return false;
        
        if (path_parts.peek() == null) {
            // This is the last component - we found it
            return true;
        }
        
        // Not the last component, must be a tree
        if (c.git_tree_entry_type(@ptrCast(entry)) != c.GIT_OBJECT_TREE) {
            return false;
        }
        
        // Look up the subtree
        const tree_oid = git.c.git_tree_entry_id(@ptrCast(entry));
        var subtree: ?*git.c.git_tree = null;
        if (git.c.git_tree_lookup(&subtree, @ptrCast(@constCast(tree_obj.tree)), tree_oid) != 0) {
            return false;
        }
        
        if (temp_tree) |*t| t.free();
        temp_tree = git.Tree{ .tree = subtree.? };
        current_tree = &temp_tree.?;
    }
    
    return false;
}

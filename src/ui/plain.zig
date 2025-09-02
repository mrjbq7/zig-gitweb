const std = @import("std");
const gitweb = @import("../gitweb.zig");
const git = @import("../git.zig");

const c = git.c;

pub fn plain(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    const path = ctx.query.get("path") orelse return error.NoPath;

    // Determine MIME type based on file extension
    const ext = std.fs.path.extension(path);
    if (ctx.cfg.mimetypes.get(ext)) |mimetype| {
        ctx.page.mimetype = mimetype;
    } else if (std.mem.eql(u8, ext, ".txt") or std.mem.eql(u8, ext, ".factor")) {
        ctx.page.mimetype = "text/plain";
    } else if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) {
        ctx.page.mimetype = "text/html";
    } else if (std.mem.eql(u8, ext, ".css")) {
        ctx.page.mimetype = "text/css";
    } else if (std.mem.eql(u8, ext, ".js")) {
        ctx.page.mimetype = "application/javascript";
    } else if (std.mem.eql(u8, ext, ".json")) {
        ctx.page.mimetype = "application/json";
    } else if (std.mem.eql(u8, ext, ".xml")) {
        ctx.page.mimetype = "application/xml";
    } else if (std.mem.eql(u8, ext, ".png")) {
        ctx.page.mimetype = "image/png";
    } else if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) {
        ctx.page.mimetype = "image/jpeg";
    } else if (std.mem.eql(u8, ext, ".gif")) {
        ctx.page.mimetype = "image/gif";
    } else if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h") or
        std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc") or
        std.mem.eql(u8, ext, ".py") or std.mem.eql(u8, ext, ".rb") or
        std.mem.eql(u8, ext, ".go") or std.mem.eql(u8, ext, ".rs") or
        std.mem.eql(u8, ext, ".zig") or std.mem.eql(u8, ext, ".java") or
        std.mem.eql(u8, ext, ".sh") or std.mem.eql(u8, ext, ".bash") or
        std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".markdown") or
        std.mem.eql(u8, ext, ".rst") or std.mem.eql(u8, ext, ".yaml") or
        std.mem.eql(u8, ext, ".yml") or std.mem.eql(u8, ext, ".toml") or
        std.mem.eql(u8, ext, ".ini") or std.mem.eql(u8, ext, ".cfg") or
        std.mem.eql(u8, ext, ".conf") or std.mem.eql(u8, ext, ".log"))
    {
        ctx.page.mimetype = "text/plain";
    } else {
        ctx.page.mimetype = "application/octet-stream";
    }

    // Open the git repository
    var git_repo = git.Repository.open(repo.path) catch {
        return error.RepositoryNotAccessible;
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
            return error.ReferenceNotFound;
        };
        defer ref.free();

        // Resolve the reference to a commit
        var commit_obj = ref.peel(git.c.GIT_OBJECT_COMMIT) catch {
            return error.CommitNotFound;
        };
        defer commit_obj.free();

        // Cast the object to a commit
        const commit_ptr = @as(*git.c.git_commit, @ptrCast(commit_obj.obj));
        break :blk git.Commit{ .commit = commit_ptr };
    };
    defer commit.free();

    // Get the tree
    var tree = try commit.tree();
    defer tree.free();

    // Navigate to the file in the tree
    var current_tree = tree;
    var path_parts = std.mem.tokenizeAny(u8, path, "/");
    var parts_list: std.ArrayList([]const u8) = .empty;
    defer parts_list.deinit(ctx.allocator);

    // Collect path parts
    while (path_parts.next()) |part| {
        try parts_list.append(ctx.allocator, part);
    }

    // Navigate through directories
    for (parts_list.items[0 .. parts_list.items.len - 1]) |part| {
        const entry = current_tree.entryByName(part) orelse {
            return error.PathNotFound;
        };

        if (c.git_tree_entry_type(@as(?*const c.git_tree_entry, @ptrCast(entry))) != c.GIT_OBJECT_TREE) {
            return error.PathNotFound;
        }

        const entry_oid = c.git_tree_entry_id(@as(?*const c.git_tree_entry, @ptrCast(entry)));
        const subtree = try git_repo.lookupTree(@constCast(entry_oid));

        if (current_tree.tree != tree.tree) {
            current_tree.free();
        }
        current_tree = subtree;
    }

    defer {
        if (current_tree.tree != tree.tree) {
            current_tree.free();
        }
    }

    // Get the final file
    const filename = parts_list.items[parts_list.items.len - 1];
    const entry = current_tree.entryByName(filename) orelse {
        return error.FileNotFound;
    };

    if (c.git_tree_entry_type(@as(?*const c.git_tree_entry, @ptrCast(entry))) != c.GIT_OBJECT_BLOB) {
        return error.NotAFile;
    }

    const entry_oid = c.git_tree_entry_id(@as(?*const c.git_tree_entry, @ptrCast(entry)));
    var blob = try git_repo.lookupBlob(@constCast(entry_oid));
    defer blob.free();

    // Serve the file content
    const content = blob.content();
    try writer.writeAll(content);
}

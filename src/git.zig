const std = @import("std");
pub const c = @cImport({
    @cInclude("git2.h");
});

pub const GitError = error{
    InitFailed,
    OpenFailed,
    NotFound,
    InvalidObject,
    InvalidReference,
    OutOfMemory,
    Unknown,
};

// Initialize libgit2 on startup
pub fn init() !void {
    if (c.git_libgit2_init() < 0) {
        return GitError.InitFailed;
    }
}

pub fn deinit() void {
    _ = c.git_libgit2_shutdown();
}

fn getLastError() GitError {
    const err = c.git_error_last();
    if (err != null) {
        std.log.err("Git error: {s}", .{err.*.message});
    }
    return GitError.Unknown;
}

pub const Repository = struct {
    repo: *c.git_repository,
    
    pub fn open(path: []const u8) !Repository {
        var repo: ?*c.git_repository = null;
        const c_path = try std.heap.c_allocator.dupeZ(u8, path);
        defer std.heap.c_allocator.free(c_path);
        
        if (c.git_repository_open(&repo, c_path) != 0) {
            return getLastError();
        }
        
        return Repository{ .repo = repo.? };
    }
    
    pub fn openBare(path: []const u8) !Repository {
        var repo: ?*c.git_repository = null;
        const c_path = try std.heap.c_allocator.dupeZ(u8, path);
        defer std.heap.c_allocator.free(c_path);
        
        if (c.git_repository_open_bare(&repo, c_path) != 0) {
            return getLastError();
        }
        
        return Repository{ .repo = repo.? };
    }
    
    pub fn close(self: *Repository) void {
        c.git_repository_free(self.repo);
    }
    
    pub fn getHead(self: *Repository) !Reference {
        var ref: ?*c.git_reference = null;
        if (c.git_repository_head(&ref, self.repo) != 0) {
            return getLastError();
        }
        return Reference{ .ref = ref.? };
    }
    
    pub fn getReference(self: *Repository, name: []const u8) !Reference {
        var ref: ?*c.git_reference = null;
        const c_name = try std.heap.c_allocator.dupeZ(u8, name);
        defer std.heap.c_allocator.free(c_name);
        
        if (c.git_reference_lookup(&ref, self.repo, c_name) != 0) {
            return getLastError();
        }
        return Reference{ .ref = ref.? };
    }
    
    pub fn lookupCommit(self: *Repository, oid: anytype) !Commit {
        var commit: ?*c.git_commit = null;
        const T = @TypeOf(oid);
        const oid_ptr: [*c]const c.git_oid = if (T == *const c.git_oid or T == *c.git_oid)
            @ptrCast(oid)
        else if (T == c.git_oid)
            @ptrCast(&oid)
        else if (T == *const *const c.git_oid)
            @ptrCast(oid.*)
        else if (T == [*c]const c.git_oid)
            oid
        else if (T == [*c]c.git_oid)
            oid
        else
            @ptrCast(oid);
        if (c.git_commit_lookup(&commit, self.repo, oid_ptr) != 0) {
            return getLastError();
        }
        return Commit{ .commit = commit.? };
    }
    
    pub fn lookupTree(self: *Repository, oid: anytype) !Tree {
        var tree: ?*c.git_tree = null;
        const T = @TypeOf(oid);
        const oid_ptr: [*c]const c.git_oid = if (T == *const c.git_oid or T == *c.git_oid)
            @ptrCast(oid)
        else if (T == c.git_oid)
            @ptrCast(&oid)
        else if (T == *const *const c.git_oid)
            @ptrCast(oid.*)
        else if (T == [*c]const c.git_oid)
            oid
        else if (T == [*c]c.git_oid)
            oid
        else
            @ptrCast(oid);
        if (c.git_tree_lookup(&tree, self.repo, oid_ptr) != 0) {
            return getLastError();
        }
        return Tree{ .tree = tree.? };
    }
    
    pub fn lookupBlob(self: *Repository, oid: anytype) !Blob {
        var blob: ?*c.git_blob = null;
        const T = @TypeOf(oid);
        const oid_ptr: [*c]const c.git_oid = if (T == *const c.git_oid or T == *c.git_oid)
            @ptrCast(oid)
        else if (T == c.git_oid)
            @ptrCast(&oid)
        else if (T == *const *const c.git_oid)
            @ptrCast(oid.*)
        else if (T == [*c]const c.git_oid)
            oid
        else if (T == [*c]c.git_oid)
            oid
        else
            @ptrCast(oid);
        if (c.git_blob_lookup(&blob, self.repo, oid_ptr) != 0) {
            return getLastError();
        }
        return Blob{ .blob = blob.? };
    }
    
    pub fn lookupObject(self: *Repository, oid: *c.git_oid, obj_type: c.git_object_t) !Object {
        var obj: ?*c.git_object = null;
        if (c.git_object_lookup(&obj, self.repo, oid, obj_type) != 0) {
            return getLastError();
        }
        return Object{ .obj = obj.? };
    }
    
    pub fn revwalk(self: *Repository) !RevWalk {
        var walk: ?*c.git_revwalk = null;
        if (c.git_revwalk_new(&walk, self.repo) != 0) {
            return getLastError();
        }
        return RevWalk{ .walk = walk.? };
    }
    
    pub fn getBranches(self: *Repository, allocator: std.mem.Allocator) ![]Branch {
        var branches: std.ArrayList(Branch) = .empty;
        errdefer branches.deinit(allocator);
        
        var iter: ?*c.git_branch_iterator = null;
        if (c.git_branch_iterator_new(&iter, self.repo, c.GIT_BRANCH_ALL) != 0) {
            return getLastError();
        }
        defer c.git_branch_iterator_free(iter);
        
        var ref: ?*c.git_reference = null;
        var branch_type: c.git_branch_t = undefined;
        
        while (c.git_branch_next(&ref, &branch_type, iter) == 0) {
            const name = c.git_reference_shorthand(ref);
            const branch = Branch{
                .name = std.mem.span(name),
                .is_remote = branch_type == c.GIT_BRANCH_REMOTE,
                .ref = Reference{ .ref = ref.? },
            };
            try branches.append(allocator, branch);
        }
        
        return branches.toOwnedSlice(allocator);
    }
    
    pub fn getTags(self: *Repository, allocator: std.mem.Allocator) ![]Tag {
        var tags: std.ArrayList(Tag) = .empty;
        errdefer tags.deinit(allocator);
        
        var tag_names: c.git_strarray = undefined;
        if (c.git_tag_list(&tag_names, self.repo) != 0) {
            return getLastError();
        }
        defer c.git_strarray_dispose(&tag_names);
        
        var i: usize = 0;
        while (i < tag_names.count) : (i += 1) {
            const name = tag_names.strings[i];
            const full_name_z = try std.fmt.allocPrintSentinel(allocator, "refs/tags/{s}", .{name}, 0);
            defer allocator.free(full_name_z);
            
            var ref: ?*c.git_reference = null;
            if (c.git_reference_lookup(&ref, self.repo, full_name_z) == 0) {
                // Duplicate the name to avoid use-after-free when git_strarray_dispose is called
                const name_copy = try allocator.dupe(u8, std.mem.span(name));
                const tag = Tag{
                    .name = name_copy,
                    .ref = Reference{ .ref = ref.? },
                };
                try tags.append(allocator, tag);
            }
        }
        
        return tags.toOwnedSlice(allocator);
    }
};

pub const Reference = struct {
    ref: *c.git_reference,
    
    pub fn free(self: *Reference) void {
        c.git_reference_free(self.ref);
    }
    
    pub fn name(self: *Reference) []const u8 {
        return std.mem.span(c.git_reference_name(self.ref));
    }
    
    pub fn shorthand(self: *Reference) []const u8 {
        return std.mem.span(c.git_reference_shorthand(self.ref));
    }
    
    pub fn target(self: *Reference) ?*const c.git_oid {
        return c.git_reference_target(self.ref);
    }
    
    pub fn peel(self: *Reference, obj_type: c.git_object_t) !Object {
        var obj: ?*c.git_object = null;
        if (c.git_reference_peel(&obj, self.ref, obj_type) != 0) {
            return getLastError();
        }
        return Object{ .obj = obj.? };
    }
};

pub const Commit = struct {
    commit: *c.git_commit,
    
    pub fn free(self: *Commit) void {
        c.git_commit_free(self.commit);
    }
    
    pub fn id(self: *Commit) *const c.git_oid {
        return c.git_commit_id(self.commit);
    }
    
    pub fn message(self: *Commit) []const u8 {
        const msg = c.git_commit_message(self.commit);
        return if (msg) |m| std.mem.span(m) else "";
    }
    
    pub fn summary(self: *Commit) []const u8 {
        const sum = c.git_commit_summary(self.commit);
        return if (sum) |s| std.mem.span(s) else "";
    }
    
    pub fn author(self: *Commit) *const c.git_signature {
        return c.git_commit_author(self.commit);
    }
    
    pub fn committer(self: *Commit) *const c.git_signature {
        return c.git_commit_committer(self.commit);
    }
    
    pub fn time(self: *Commit) i64 {
        return c.git_commit_time(self.commit);
    }
    
    pub fn parentCount(self: *Commit) u32 {
        return c.git_commit_parentcount(self.commit);
    }
    
    pub fn parent(self: *Commit, n: u32) !Commit {
        var parent_commit: ?*c.git_commit = null;
        if (c.git_commit_parent(&parent_commit, self.commit, n) != 0) {
            return getLastError();
        }
        return Commit{ .commit = parent_commit.? };
    }
    
    pub fn tree(self: *Commit) !Tree {
        var tree_obj: ?*c.git_tree = null;
        if (c.git_commit_tree(&tree_obj, self.commit) != 0) {
            return getLastError();
        }
        return Tree{ .tree = tree_obj.? };
    }
};

pub const Tree = struct {
    tree: *c.git_tree,
    
    pub fn free(self: *Tree) void {
        c.git_tree_free(self.tree);
    }
    
    pub fn id(self: *Tree) *const c.git_oid {
        return c.git_tree_id(self.tree);
    }
    
    pub fn entryCount(self: *Tree) usize {
        return c.git_tree_entrycount(self.tree);
    }
    
    pub fn entryByIndex(self: *Tree, idx: usize) ?*const c.git_tree_entry {
        return c.git_tree_entry_byindex(self.tree, idx);
    }
    
    pub fn entryByName(self: *Tree, name: []const u8) ?*const c.git_tree_entry {
        const c_name = std.heap.c_allocator.dupeZ(u8, name) catch return null;
        defer std.heap.c_allocator.free(c_name);
        return c.git_tree_entry_byname(self.tree, c_name);
    }
    
    pub fn walk(self: *Tree, callback: c.git_treewalk_cb, payload: ?*anyopaque) !void {
        if (c.git_tree_walk(self.tree, c.GIT_TREEWALK_PRE, callback, payload) != 0) {
            return getLastError();
        }
    }
};

pub const Blob = struct {
    blob: *c.git_blob,
    
    pub fn free(self: *Blob) void {
        c.git_blob_free(self.blob);
    }
    
    pub fn id(self: *Blob) *const c.git_oid {
        return c.git_blob_id(self.blob);
    }
    
    pub fn size(self: *Blob) u64 {
        return @intCast(c.git_blob_rawsize(self.blob));
    }
    
    pub fn content(self: *Blob) []const u8 {
        const ptr = c.git_blob_rawcontent(self.blob);
        const len = self.size();
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }
    
    pub fn isBinary(self: *Blob) bool {
        return c.git_blob_is_binary(self.blob) != 0;
    }
};

pub const Object = struct {
    obj: *c.git_object,
    
    pub fn free(self: *Object) void {
        c.git_object_free(self.obj);
    }
    
    pub fn id(self: *Object) *const c.git_oid {
        return c.git_object_id(self.obj);
    }
    
    pub fn @"type"(self: *Object) c.git_object_t {
        return c.git_object_type(self.obj);
    }
};

pub const RevWalk = struct {
    walk: *c.git_revwalk,
    
    pub fn free(self: *RevWalk) void {
        c.git_revwalk_free(self.walk);
    }
    
    pub fn pushHead(self: *RevWalk) !void {
        if (c.git_revwalk_push_head(self.walk) != 0) {
            return getLastError();
        }
    }
    
    pub fn pushRef(self: *RevWalk, refname: []const u8) !void {
        const c_name = try std.heap.c_allocator.dupeZ(u8, refname);
        defer std.heap.c_allocator.free(c_name);
        
        if (c.git_revwalk_push_ref(self.walk, c_name) != 0) {
            return getLastError();
        }
    }
    
    pub fn hide(self: *RevWalk, oid: *const c.git_oid) !void {
        if (c.git_revwalk_hide(self.walk, oid) != 0) {
            return getLastError();
        }
    }
    
    pub fn setSorting(self: *RevWalk, sort_mode: u32) void {
        _ = c.git_revwalk_sorting(self.walk, sort_mode);
    }
    
    pub fn next(self: *RevWalk) ?c.git_oid {
        var oid: c.git_oid = undefined;
        if (c.git_revwalk_next(&oid, self.walk) == 0) {
            return oid;
        }
        return null;
    }
};

pub const Diff = struct {
    diff: *c.git_diff,
    
    pub fn free(self: *Diff) void {
        c.git_diff_free(self.diff);
    }
    
    pub fn treeToTree(repo: *c.git_repository, old_tree: ?*c.git_tree, new_tree: ?*c.git_tree, opts: ?*c.git_diff_options) !Diff {
        var diff: ?*c.git_diff = null;
        if (c.git_diff_tree_to_tree(&diff, repo, old_tree, new_tree, opts) != 0) {
            return getLastError();
        }
        return Diff{ .diff = diff.? };
    }
    
    pub fn treeToWorkdir(repo: *c.git_repository, tree: ?*c.git_tree, opts: ?*c.git_diff_options) !Diff {
        var diff: ?*c.git_diff = null;
        if (c.git_diff_tree_to_workdir(&diff, repo, tree, opts) != 0) {
            return getLastError();
        }
        return Diff{ .diff = diff.? };
    }
    
    pub fn numDeltas(self: *Diff) usize {
        return c.git_diff_num_deltas(self.diff);
    }
    
    pub fn getDelta(self: *Diff, idx: usize) ?*const c.git_diff_delta {
        return c.git_diff_get_delta(self.diff, idx);
    }
    
    pub fn print(self: *Diff, format: c.git_diff_format_t, callback: c.git_diff_line_cb, payload: ?*anyopaque) !void {
        if (c.git_diff_print(self.diff, format, callback, payload) != 0) {
            return getLastError();
        }
    }
    
    pub fn getStats(self: *Diff) !DiffStats {
        var stats: ?*c.git_diff_stats = null;
        if (c.git_diff_get_stats(&stats, self.diff) != 0) {
            return getLastError();
        }
        return DiffStats{ .stats = stats.? };
    }
};

pub const DiffStats = struct {
    stats: *c.git_diff_stats,
    
    pub fn free(self: *DiffStats) void {
        c.git_diff_stats_free(self.stats);
    }
    
    pub fn filesChanged(self: *DiffStats) usize {
        return @intCast(c.git_diff_stats_files_changed(self.stats));
    }
    
    pub fn insertions(self: *DiffStats) usize {
        return @intCast(c.git_diff_stats_insertions(self.stats));
    }
    
    pub fn deletions(self: *DiffStats) usize {
        return @intCast(c.git_diff_stats_deletions(self.stats));
    }
};

pub const Blame = struct {
    blame: *c.git_blame,
    
    pub fn free(self: *Blame) void {
        c.git_blame_free(self.blame);
    }
    
    pub fn file(repo: *c.git_repository, path: []const u8, opts: ?*c.git_blame_options) !Blame {
        var blame: ?*c.git_blame = null;
        const c_path = try std.heap.c_allocator.dupeZ(u8, path);
        defer std.heap.c_allocator.free(c_path);
        
        if (c.git_blame_file(&blame, repo, c_path, opts) != 0) {
            return getLastError();
        }
        return Blame{ .blame = blame.? };
    }
    
    pub fn getHunkCount(self: *Blame) u32 {
        return c.git_blame_get_hunk_count(self.blame);
    }
    
    pub fn getHunkByIndex(self: *Blame, index: u32) ?*const c.git_blame_hunk {
        return c.git_blame_get_hunk_byindex(self.blame, index);
    }
    
    pub fn getHunkByLine(self: *Blame, lineno: usize) ?*const c.git_blame_hunk {
        return c.git_blame_get_hunk_byline(self.blame, lineno);
    }
};

pub const Branch = struct {
    name: []const u8,
    is_remote: bool,
    ref: Reference,
};

pub const Tag = struct {
    name: []const u8,
    ref: Reference,
};

pub fn oidToString(oid: *const c.git_oid) ![40]u8 {
    var buf: [41]u8 = undefined;
    _ = c.git_oid_tostr(&buf, buf.len, oid);
    return buf[0..40].*;
}

pub fn stringToOid(str: []const u8) !c.git_oid {
    var oid: c.git_oid = undefined;
    const c_str = try std.heap.c_allocator.dupeZ(u8, str);
    defer std.heap.c_allocator.free(c_str);
    
    if (c.git_oid_fromstr(&oid, c_str) != 0) {
        return GitError.InvalidObject;
    }
    return oid;
}

pub fn signatureToString(sig: *const c.git_signature, allocator: std.mem.Allocator) ![]const u8 {
    const name = std.mem.span(sig.name);
    const email = std.mem.span(sig.email);
    return std.fmt.allocPrint(allocator, "{s} <{s}>", .{ name, email });
}

pub fn getFileMode(mode: u32) []const u8 {
    return switch (mode) {
        0o040000 => "d---------",
        0o100644 => "-rw-r--r--",
        0o100755 => "-rwxr-xr-x",
        0o120000 => "lrwxrwxrwx",
        0o160000 => "m---------", // Submodule
        else => "----------",
    };
}
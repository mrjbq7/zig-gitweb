const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = git.c;

pub fn branches(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='branches'>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Structure to hold branch information
    const BranchInfo = struct {
        name: []const u8,
        branch_type: c.git_branch_t,
        is_head: bool,
        oid_str: [40]u8,
        author_name: []const u8,
        message: []const u8,
        timestamp: i64,
    };

    // Collect all branches
    var branch_list: std.ArrayList(BranchInfo) = .empty;
    defer {
        for (branch_list.items) |branch| {
            ctx.allocator.free(branch.name);
            ctx.allocator.free(branch.author_name);
            ctx.allocator.free(branch.message);
        }
        branch_list.deinit(ctx.allocator);
    }

    // Get all branches
    var branch_iter: ?*c.git_branch_iterator = null;
    if (c.git_branch_iterator_new(&branch_iter, @ptrCast(git_repo.repo), c.GIT_BRANCH_ALL) != 0) {
        try writer.writeAll("<p>Unable to get branches</p>\n");
        try writer.writeAll("</div>\n");
        try writer.writeAll("</div>\n");
        return;
    }
    defer c.git_branch_iterator_free(branch_iter);

    var ref: ?*c.git_reference = null;
    var branch_type: c.git_branch_t = undefined;

    // Get HEAD ref for comparison
    var head_ref: ?*c.git_reference = null;
    const has_head = c.git_repository_head(&head_ref, @ptrCast(git_repo.repo)) == 0;
    defer if (has_head) c.git_reference_free(head_ref);

    while (c.git_branch_next(&ref, &branch_type, branch_iter) == 0) {
        defer c.git_reference_free(ref);

        const branch_name = c.git_reference_shorthand(ref) orelse continue;
        const target = c.git_reference_target(ref);

        if (target == null) continue;

        // Get commit info
        var commit = git_repo.lookupCommit(target.?) catch continue;
        defer commit.free();

        const oid_str = try git.oidToString(commit.id());
        const author = commit.author();
        const commit_time = commit.time();
        const commit_message = commit.message();

        // Check if this is the current branch
        const is_head = has_head and branch_type == c.GIT_BRANCH_LOCAL and
            c.git_reference_cmp(ref, head_ref) == 0;

        var oid_buf: [40]u8 = undefined;
        @memcpy(&oid_buf, oid_str[0..40]);

        try branch_list.append(ctx.allocator, BranchInfo{
            .name = try ctx.allocator.dupe(u8, std.mem.span(branch_name)),
            .branch_type = branch_type,
            .is_head = is_head,
            .oid_str = oid_buf,
            .author_name = try ctx.allocator.dupe(u8, std.mem.span(author.name)),
            .message = try ctx.allocator.dupe(u8, commit_message),
            .timestamp = commit_time,
        });
    }

    // Sort branches: local first, then by timestamp
    std.mem.sort(BranchInfo, branch_list.items, {}, struct {
        fn lessThan(_: void, a: BranchInfo, b: BranchInfo) bool {
            if (a.branch_type != b.branch_type) {
                return a.branch_type == c.GIT_BRANCH_LOCAL;
            }
            return a.timestamp > b.timestamp;
        }
    }.lessThan);

    // Display local branches first
    try writer.writeAll("<h2>Branches</h2>\n");
    try writer.writeAll("<div class='refs-list'>\n");

    var has_local = false;
    var has_remote = false;

    for (branch_list.items) |branch| {
        if (branch.branch_type == c.GIT_BRANCH_LOCAL) {
            has_local = true;
            try shared.writeBranchItem(ctx, writer, shared.BranchItemInfo{
                .name = branch.name,
                .is_head = branch.is_head,
                .oid_str = branch.oid_str,
                .author_name = branch.author_name,
                .message = branch.message,
                .timestamp = branch.timestamp,
            }, "refs");
        } else {
            has_remote = true;
        }
    }

    if (!has_local) {
        try writer.writeAll("<p>No local branches found.</p>\n");
    }
    try writer.writeAll("</div>\n");

    // Display remote branches if any
    if (has_remote) {
        try writer.writeAll("<h2>Remote Branches</h2>\n");
        try writer.writeAll("<div class='refs-list'>\n");

        for (branch_list.items) |branch| {
            if (branch.branch_type == c.GIT_BRANCH_REMOTE) {
                try shared.writeBranchItem(ctx, writer, shared.BranchItemInfo{
                    .name = branch.name,
                    .is_head = branch.is_head,
                    .oid_str = branch.oid_str,
                    .author_name = branch.author_name,
                    .message = branch.message,
                    .timestamp = branch.timestamp,
                }, "refs");
            }
        }

        try writer.writeAll("</div>\n");
    }

    try writer.writeAll("</div>\n"); // Close branches
}

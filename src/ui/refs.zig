const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn refs(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='refs'>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Show branches
    try showBranches(ctx, &git_repo, writer);

    // Show tags
    try showTags(ctx, &git_repo, writer);

    try writer.writeAll("</div>\n");
}

fn showBranches(ctx: *gitweb.Context, repo: *git.Repository, writer: anytype) !void {
    try writer.writeAll("<h2>Branches</h2>\n");
    try writer.writeAll("<div class='refs-list'>\n");

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
    var branches: std.ArrayList(BranchInfo) = .empty;
    defer {
        for (branches.items) |branch| {
            ctx.allocator.free(branch.name);
            ctx.allocator.free(branch.author_name);
            ctx.allocator.free(branch.message);
        }
        branches.deinit(ctx.allocator);
    }

    // Get all branches
    var branch_list: ?*c.git_branch_iterator = null;
    if (c.git_branch_iterator_new(&branch_list, @ptrCast(repo.repo), c.GIT_BRANCH_ALL) != 0) {
        try writer.writeAll("<tr><td colspan='4'>Unable to get branches</td></tr>\n");
        try html.writeTableFooter(writer);
        return;
    }
    defer c.git_branch_iterator_free(branch_list);

    var ref: ?*c.git_reference = null;
    var branch_type: c.git_branch_t = undefined;

    // Get HEAD ref for comparison
    var head_ref: ?*c.git_reference = null;
    const has_head = c.git_repository_head(&head_ref, @ptrCast(repo.repo)) == 0;
    defer if (has_head) c.git_reference_free(head_ref);

    while (c.git_branch_next(&ref, &branch_type, branch_list) == 0) {
        defer c.git_reference_free(ref);

        const branch_name = c.git_reference_shorthand(ref) orelse continue;
        const target = c.git_reference_target(ref);

        if (target == null) continue;

        // Get commit info
        var commit = repo.lookupCommit(target.?) catch continue;
        defer commit.free();

        const oid_str = try git.oidToString(commit.id());
        const author = commit.author();
        const commit_time = commit.time();

        // Check if this is the current branch
        const is_head = has_head and branch_type == c.GIT_BRANCH_LOCAL and
            c.git_reference_cmp(ref, head_ref) == 0;

        var oid_buf: [40]u8 = undefined;
        @memcpy(&oid_buf, oid_str[0..40]);

        try branches.append(ctx.allocator, BranchInfo{
            .name = try ctx.allocator.dupe(u8, std.mem.span(branch_name)),
            .branch_type = branch_type,
            .is_head = is_head,
            .oid_str = oid_buf,
            .author_name = try ctx.allocator.dupe(u8, std.mem.span(author.name)),
            .message = try ctx.allocator.dupe(u8, commit.summary()),
            .timestamp = commit_time,
        });
    }

    // Sort branches: local first, then remote, alphabetically within each group
    std.sort.pdq(BranchInfo, branches.items, {}, struct {
        fn lessThan(_: void, a: BranchInfo, b: BranchInfo) bool {
            // Local branches come before remote branches
            if (a.branch_type == c.GIT_BRANCH_LOCAL and b.branch_type == c.GIT_BRANCH_REMOTE) {
                return true;
            }
            if (a.branch_type == c.GIT_BRANCH_REMOTE and b.branch_type == c.GIT_BRANCH_LOCAL) {
                return false;
            }
            // Within the same type, sort alphabetically
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    // Display sorted branches
    for (branches.items) |branch| {
        if (branch.branch_type == c.GIT_BRANCH_REMOTE) {
            // For remote branches, add prefix to the name
            const prefixed_name = try std.fmt.allocPrint(ctx.allocator, "remotes/{s}", .{branch.name});
            defer ctx.allocator.free(prefixed_name);

            try shared.writeBranchItem(ctx, writer, shared.BranchItemInfo{
                .name = prefixed_name,
                .is_head = branch.is_head,
                .oid_str = branch.oid_str,
                .author_name = branch.author_name,
                .message = branch.message,
                .timestamp = branch.timestamp,
            }, "refs");
        } else {
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

    if (branches.items.len == 0) {
        try writer.writeAll("<div class='refs-empty'>No branches found</div>\n");
    }

    try writer.writeAll("</div>\n"); // refs-list
}

fn showTags(ctx: *gitweb.Context, repo: *git.Repository, writer: anytype) !void {
    try writer.writeAll("<h2>Tags</h2>\n");
    try writer.writeAll("<div class='refs-list'>\n");

    // Get all tags
    var tag_names: c.git_strarray = undefined;
    if (c.git_tag_list(&tag_names, @ptrCast(repo.repo)) != 0) {
        try writer.writeAll("<tr><td colspan='4'>Unable to get tags</td></tr>\n");
        try html.writeTableFooter(writer);
        return;
    }
    defer c.git_strarray_dispose(&tag_names);

    // Process tags (newest first)
    var tags: std.ArrayList(TagInfo) = .empty;
    defer {
        for (tags.items) |*tag| {
            if (tag.tag_obj) |t| c.git_object_free(@ptrCast(t));
        }
        tags.deinit(ctx.allocator);
    }

    for (0..tag_names.count) |i| {
        const tag_name = tag_names.strings[i];

        var ref: ?*c.git_reference = null;
        const ref_name = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/tags/{s}", .{std.mem.span(tag_name)}, 0);
        defer ctx.allocator.free(ref_name);

        if (c.git_reference_lookup(&ref, @ptrCast(repo.repo), ref_name) != 0) continue;
        defer c.git_reference_free(ref);

        var tag_info = TagInfo{
            .name = std.mem.span(tag_name),
            .tag_obj = null,
            .target_oid = undefined,
            .tagger_time = 0,
            .tagger_name = "",
            .message = "",
            .commit_message = "",
        };

        const oid = c.git_reference_target(ref);
        if (oid == null) continue;

        // Check if it's an annotated tag
        var tag_obj: ?*c.git_tag = null;
        if (c.git_tag_lookup(&tag_obj, @ptrCast(repo.repo), oid) == 0) {
            // Annotated tag
            tag_info.tag_obj = tag_obj;
            tag_info.target_oid = c.git_tag_target_id(tag_obj).*;

            const tagger = c.git_tag_tagger(tag_obj);
            if (tagger != null) {
                tag_info.tagger_time = @intCast(tagger.*.when.time);
                tag_info.tagger_name = std.mem.span(tagger.*.name);
            }

            const msg = c.git_tag_message(tag_obj);
            if (msg != null) {
                tag_info.message = std.mem.span(msg);
            }

            // Get commit message for annotated tags
            var commit = repo.lookupCommit(&tag_info.target_oid) catch {
                tag_info.commit_message = "";
                try tags.append(ctx.allocator, tag_info);
                continue;
            };
            defer commit.free();
            tag_info.commit_message = commit.summary();
        } else {
            // Lightweight tag
            tag_info.target_oid = oid.*;

            // Get commit time and message for lightweight tags
            var commit = repo.lookupCommit(&tag_info.target_oid) catch continue;
            defer commit.free();
            tag_info.tagger_time = commit.time();
            tag_info.commit_message = commit.summary();
        }

        try tags.append(ctx.allocator, tag_info);
    }

    // Sort tags reverse-alphabetically with natural/human sort
    std.sort.pdq(TagInfo, tags.items, {}, struct {
        fn lessThan(_: void, a: TagInfo, b: TagInfo) bool {
            // Human/natural sort - compare version numbers properly
            return humanCompare(b.name, a.name); // Reversed for descending order
        }
    }.lessThan);

    // Display tags
    for (tags.items) |tag| {
        // Get OID string for the tag
        const oid_str = try git.oidToString(@ptrCast(&tag.target_oid));
        var oid_buf: [40]u8 = undefined;
        @memcpy(&oid_buf, oid_str[0..40]);

        // Determine the author name
        const author_name = if (tag.tag_obj != null and tag.tagger_name.len > 0)
            tag.tagger_name
        else blk: {
            // For lightweight tags, get commit author
            var commit = repo.lookupCommit(@as(*const git.c.git_oid, @ptrCast(&tag.target_oid))) catch {
                break :blk "-";
            };
            defer commit.free();
            const author = commit.author();
            break :blk std.mem.span(author.name);
        };

        // Create tag name with annotated badge if applicable
        const display_name = if (tag.tag_obj != null)
            try std.fmt.allocPrint(ctx.allocator, "{s} <span class='refs-annotated-badge'>annotated</span>", .{tag.name})
        else
            tag.name;
        defer if (tag.tag_obj != null) ctx.allocator.free(display_name);

        try shared.writeTagItem(ctx, writer, shared.TagItemInfo{
            .name = tag.name,
            .oid_str = oid_buf,
            .author_name = author_name,
            .message = tag.commit_message,
            .timestamp = if (tag.tagger_time > 0) tag.tagger_time else 0,
        }, "refs");
    }

    if (tags.items.len == 0) {
        try writer.writeAll("<div class='refs-empty'>No tags found</div>\n");
    }

    try writer.writeAll("</div>\n"); // refs-list
}

const TagInfo = struct {
    name: []const u8,
    tag_obj: ?*c.git_tag,
    target_oid: c.git_oid,
    tagger_time: i64,
    tagger_name: []const u8,
    message: []const u8,
    commit_message: []const u8,
};

// Human/natural comparison function for version-like strings
fn humanCompare(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;

    while (i < a.len and j < b.len) {
        // Check if we're at a number in both strings
        const a_is_digit = std.ascii.isDigit(a[i]);
        const b_is_digit = std.ascii.isDigit(b[j]);

        if (a_is_digit and b_is_digit) {
            // Compare numbers numerically
            var a_num: u64 = 0;
            while (i < a.len and std.ascii.isDigit(a[i])) {
                a_num = a_num * 10 + (a[i] - '0');
                i += 1;
            }

            var b_num: u64 = 0;
            while (j < b.len and std.ascii.isDigit(b[j])) {
                b_num = b_num * 10 + (b[j] - '0');
                j += 1;
            }

            if (a_num != b_num) {
                return a_num < b_num;
            }
        } else if (!a_is_digit and !b_is_digit) {
            // Compare characters
            if (a[i] != b[j]) {
                return a[i] < b[j];
            }
            i += 1;
            j += 1;
        } else {
            // One is digit, one isn't - non-digit comes first
            return !a_is_digit;
        }
    }

    // Shorter string comes first
    return a.len < b.len;
}

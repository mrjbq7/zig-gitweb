const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = git.c;

pub fn summary(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='summary'>\n");

    // Show additional repository info if available
    if (repo.homepage) |homepage| {
        try writer.writeAll("<div class='homepage'>Homepage: ");
        try html.writeLink(writer, homepage, homepage);
        try writer.writeAll("</div>\n");
    }

    if (repo.owner) |owner| {
        try writer.writeAll("<div class='owner'>Owner: ");
        try html.htmlEscape(writer, owner);
        try writer.writeAll("</div>\n");
    }

    if (repo.clone_url) |clone_url| {
        try writer.writeAll("<div class='clone-url'>Clone URL: <code>");
        try html.htmlEscape(writer, clone_url);
        try writer.writeAll("</code></div>\n");
    }

    // Show recent commits
    try showRecentCommits(ctx, repo, writer);

    // Show branches
    try showBranches(ctx, repo, writer);

    // Show tags
    try showTags(ctx, repo, writer);

    try writer.writeAll("</div>\n");
}

fn showRecentCommits(ctx: *gitweb.Context, repo: *gitweb.Repo, writer: anytype) !void {
    try writer.writeAll("<h2>Recent Commits</h2>\n");
    try writer.writeAll("<div class='log-list'>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // First, collect all refs (branches and tags) into a map
    var refs_map = std.StringHashMap(std.ArrayList(shared.CommitItemInfo.RefInfo)).init(ctx.allocator);
    defer {
        var it = refs_map.iterator();
        while (it.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*);
            // Free the duplicated ref names
            for (entry.value_ptr.items) |ref_info| {
                ctx.allocator.free(ref_info.name);
            }
            entry.value_ptr.deinit(ctx.allocator);
        }
        refs_map.deinit();
    }

    // Get branches
    const branches = try git_repo.getBranches(ctx.allocator);
    defer ctx.allocator.free(branches);

    for (branches) |branch| {
        defer @constCast(&branch.ref).free();
        if (!branch.is_remote) {
            const target = @constCast(&branch.ref).target() orelse continue;
            const oid_str = try git.oidToString(target);

            // Only allocate if needed
            const result = try refs_map.getOrPut(oid_str[0..40]);
            if (!result.found_existing) {
                const key = try ctx.allocator.dupe(u8, oid_str[0..40]);
                result.key_ptr.* = key;
                result.value_ptr.* = std.ArrayList(shared.CommitItemInfo.RefInfo).empty;
            }
            try result.value_ptr.append(ctx.allocator, .{
                .name = try ctx.allocator.dupe(u8, branch.name),
                .ref_type = .branch,
            });
        }
    }

    // Get tags
    const tags = try git_repo.getTags(ctx.allocator);
    defer {
        for (tags) |tag| {
            ctx.allocator.free(tag.name);
            @constCast(&tag.ref).free();
        }
        ctx.allocator.free(tags);
    }

    for (tags) |tag| {
        const target = @constCast(&tag.ref).target() orelse continue;
        const oid_str = try git.oidToString(target);

        // Only allocate if needed
        const result = try refs_map.getOrPut(oid_str[0..40]);
        if (!result.found_existing) {
            const key = try ctx.allocator.dupe(u8, oid_str[0..40]);
            result.key_ptr.* = key;
            result.value_ptr.* = std.ArrayList(shared.CommitItemInfo.RefInfo).empty;
        }
        try result.value_ptr.append(ctx.allocator, .{
            .name = try ctx.allocator.dupe(u8, tag.name),
            .ref_type = .tag,
        });
    }

    var walk = try git_repo.revwalk();
    defer walk.free();

    // Get the branch from query parameter or use HEAD
    const ref_name = ctx.query.get("h") orelse "HEAD";
    if (std.mem.eql(u8, ref_name, "HEAD")) {
        try walk.pushHead();
    } else {
        // Push the specific branch reference
        const full_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_name}, 0);
        defer ctx.allocator.free(full_ref);
        walk.pushRef(full_ref) catch {
            // If the full ref doesn't work, try the name as-is (might be a tag or full ref already)
            walk.pushRef(ref_name) catch {
                // Fall back to HEAD if the reference doesn't exist
                try walk.pushHead();
            };
        };
    }
    walk.setSorting(@import("../git.zig").c.GIT_SORT_TIME);

    var count: u32 = 0;
    while (walk.next()) |oid| {
        if (count >= ctx.cfg.summary_log) break;
        count += 1;

        var commit = try git_repo.lookupCommit(&oid);
        defer commit.free();

        const oid_str = try git.oidToString(commit.id());
        const author_sig = commit.author();
        const commit_time = commit.time();
        const commit_summary = commit.summary();

        var oid_buf: [40]u8 = undefined;
        @memcpy(&oid_buf, oid_str[0..40]);

        const truncated = parsing.truncateString(commit_summary, @intCast(ctx.cfg.max_msg_len));

        // Get refs for this commit if any
        const refs = if (refs_map.get(&oid_str)) |ref_list|
            ref_list.items
        else
            null;

        // Use shared rendering function
        try shared.writeCommitItem(ctx, writer, shared.CommitItemInfo{
            .oid_str = oid_buf,
            .message = truncated,
            .author_name = std.mem.span(author_sig.name),
            .timestamp = commit_time,
            .refs = refs,
        }, "log");
    }

    try writer.writeAll("</div>\n"); // log-list
}

fn showBranches(ctx: *gitweb.Context, repo: *gitweb.Repo, writer: anytype) !void {
    try writer.writeAll("<h2>Recent Branches</h2>\n");
    try writer.writeAll("<div class='refs-list'>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    const branches = try git_repo.getBranches(ctx.allocator);
    defer ctx.allocator.free(branches);

    if (branches.len == 0) {
        try writer.writeAll("<p>No branches found.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    }

    // Get HEAD reference for comparison
    const head_ref = git_repo.getHead() catch null;
    defer if (head_ref) |ref| @constCast(&ref).free();
    const head_name = if (head_ref) |ref| @constCast(&ref).name() else null;

    // Structure to hold branch data with timestamp for sorting
    const BranchInfo = struct {
        branch: git.Branch,
        timestamp: i64,
        oid_str: [40]u8,
        author_name: []const u8,
        message: []const u8,
        is_head: bool,
    };

    // Collect branch info with timestamps
    var branch_infos: std.ArrayList(BranchInfo) = .empty;
    defer {
        for (branch_infos.items) |info| {
            @constCast(&info.branch.ref).free();
        }
        branch_infos.deinit(ctx.allocator);
    }

    for (branches) |branch| {
        if (!branch.is_remote) {
            const target = @constCast(&branch.ref).target() orelse continue;
            var commit = git_repo.lookupCommit(target) catch continue;
            defer commit.free();

            const oid_str = try git.oidToString(commit.id());
            const author_sig = commit.author();
            const commit_time = commit.time();
            const commit_message = commit.message(); // Get full message, not summary

            var oid_buf: [40]u8 = undefined;
            @memcpy(&oid_buf, oid_str[0..40]);

            const is_head = if (head_name) |h| std.mem.eql(u8, @constCast(&branch.ref).name(), h) else false;

            try branch_infos.append(ctx.allocator, BranchInfo{
                .branch = branch,
                .timestamp = commit_time,
                .oid_str = oid_buf,
                .author_name = std.mem.span(author_sig.name),
                .message = commit_message,
                .is_head = is_head,
            });
        }
    }

    // Sort branches by timestamp (most recent first)
    std.mem.sort(BranchInfo, branch_infos.items, {}, struct {
        fn lessThan(_: void, a: BranchInfo, b: BranchInfo) bool {
            return a.timestamp > b.timestamp;
        }
    }.lessThan);

    var shown: u32 = 0;
    for (branch_infos.items) |info| {
        if (shown >= ctx.cfg.summary_branches) break;
        shown += 1;

        // Use shared rendering function
        try shared.writeBranchItem(ctx, writer, shared.BranchItemInfo{
            .name = info.branch.name,
            .is_head = info.is_head,
            .oid_str = info.oid_str,
            .author_name = info.author_name,
            .message = info.message,
            .timestamp = info.timestamp,
        }, "refs");
    }

    try writer.writeAll("</div>\n"); // refs-list
}

fn showTags(ctx: *gitweb.Context, repo: *gitweb.Repo, writer: anytype) !void {
    try writer.writeAll("<h2>Recent Tags</h2>\n");
    try writer.writeAll("<div class='refs-list'>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    const tags = try git_repo.getTags(ctx.allocator);
    defer {
        for (tags) |tag| {
            ctx.allocator.free(tag.name);
        }
        ctx.allocator.free(tags);
    }

    if (tags.len == 0) {
        try writer.writeAll("<p>No tags found.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    }

    // Structure to hold tag data with timestamp for sorting
    const TagInfo = struct {
        tag: git.Tag,
        timestamp: i64,
        oid_str: [40]u8,
        author_name: []const u8,
        message: []const u8,
    };

    // Collect tag info with timestamps
    var tag_infos: std.ArrayList(TagInfo) = .empty;
    defer {
        for (tag_infos.items) |info| {
            @constCast(&info.tag.ref).free();
        }
        tag_infos.deinit(ctx.allocator);
    }

    for (tags) |tag| {
        const target = @constCast(&tag.ref).target() orelse continue;

        // Try to get tag message from annotated tag, or commit message from lightweight tag
        var message_to_use: []const u8 = "";

        // Check if this is an annotated tag
        var tag_obj: ?*c.git_tag = null;
        if (c.git_tag_lookup(&tag_obj, @ptrCast(git_repo.repo), target) == 0 and tag_obj != null) {
            defer c.git_object_free(@ptrCast(tag_obj));

            // Get the tag message for annotated tags
            const tag_msg = c.git_tag_message(tag_obj);
            if (tag_msg != null) {
                message_to_use = std.mem.span(tag_msg);
            }
        }

        // Get the commit that the tag points to
        var obj = @constCast(&tag.ref).peel(@import("../git.zig").c.GIT_OBJECT_COMMIT) catch continue;
        defer obj.free();

        var commit = try git_repo.lookupCommit(obj.id());
        defer commit.free();

        const oid_str = try git.oidToString(target);
        const author_sig = commit.author();
        const commit_time = commit.time();

        // If we didn't get a tag message (lightweight tag), use commit message
        if (message_to_use.len == 0) {
            message_to_use = commit.message();
        }

        var oid_buf: [40]u8 = undefined;
        @memcpy(&oid_buf, oid_str[0..40]);

        try tag_infos.append(ctx.allocator, TagInfo{
            .tag = tag,
            .timestamp = commit_time,
            .oid_str = oid_buf,
            .author_name = std.mem.span(author_sig.name),
            .message = message_to_use,
        });
    }

    // Sort tags by timestamp (most recent first)
    std.mem.sort(TagInfo, tag_infos.items, {}, struct {
        fn lessThan(_: void, a: TagInfo, b: TagInfo) bool {
            return a.timestamp > b.timestamp;
        }
    }.lessThan);

    var shown: u32 = 0;
    for (tag_infos.items) |info| {
        if (shown >= ctx.cfg.summary_tags) break;
        shown += 1;

        // Use shared rendering function
        try shared.writeTagItem(ctx, writer, shared.TagItemInfo{
            .name = info.tag.name,
            .oid_str = info.oid_str,
            .author_name = info.author_name,
            .message = info.message,
            .timestamp = info.timestamp,
        }, "refs");
    }

    try writer.writeAll("</div>\n"); // refs-list
}

pub fn about(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='about'>\n");
    try writer.print("<h2>About {s}</h2>\n", .{repo.name});

    // TODO: Read and render README file
    try writer.writeAll("<p>README content will be shown here.</p>\n");

    try writer.writeAll("</div>\n");
}

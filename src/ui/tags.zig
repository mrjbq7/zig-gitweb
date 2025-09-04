const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = git.c;

pub fn tags(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='tags'>\n");
    try writer.writeAll("<h2>Tags</h2>\n");
    try writer.writeAll("<div class='refs-list'>\n");

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Structure to hold tag information
    const TagInfo = struct {
        name: []const u8,
        oid_str: [40]u8,
        author_name: []const u8,
        message: []const u8,
        timestamp: i64,
    };

    // Collect all tags
    var tag_list: std.ArrayList(TagInfo) = .empty;
    defer {
        for (tag_list.items) |tag| {
            ctx.allocator.free(tag.name);
            ctx.allocator.free(tag.author_name);
            ctx.allocator.free(tag.message);
        }
        tag_list.deinit(ctx.allocator);
    }

    // Get all tags
    var tag_names: c.git_strarray = undefined;
    if (c.git_tag_list(&tag_names, @ptrCast(git_repo.repo)) != 0) {
        try writer.writeAll("<p>No tags found</p>\n");
        try writer.writeAll("</div>\n");
        try writer.writeAll("</div>\n");
        return;
    }
    defer c.git_strarray_dispose(&tag_names);

    for (0..tag_names.count) |i| {
        const tag_name = tag_names.strings[i];

        // Get the tag reference
        var ref: ?*c.git_reference = null;
        const ref_name = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/tags/{s}", .{std.mem.span(tag_name)}, 0);
        defer ctx.allocator.free(ref_name);

        if (c.git_reference_lookup(&ref, @ptrCast(git_repo.repo), ref_name) != 0) continue;
        defer c.git_reference_free(ref);

        const target_oid = c.git_reference_target(ref) orelse continue;

        // Try to get tag message from annotated tag, or commit message from lightweight tag
        var message_to_use: []const u8 = "";
        var author_name_to_use: []const u8 = "";
        var timestamp_to_use: i64 = 0;

        // Check if this is an annotated tag
        var tag_obj: ?*c.git_tag = null;
        if (c.git_tag_lookup(&tag_obj, @ptrCast(git_repo.repo), target_oid) == 0 and tag_obj != null) {
            defer c.git_object_free(@ptrCast(tag_obj));

            // Get the tag message for annotated tags
            const tag_msg = c.git_tag_message(tag_obj);
            if (tag_msg != null) {
                message_to_use = try ctx.allocator.dupe(u8, std.mem.span(tag_msg));
            }

            // Get tagger info if available
            const tagger = c.git_tag_tagger(tag_obj);
            if (tagger != null) {
                author_name_to_use = try ctx.allocator.dupe(u8, std.mem.span(tagger.*.name));
                timestamp_to_use = tagger.*.when.time;
            }

            // Get the actual commit the tag points to
            const commit_oid = c.git_tag_target_id(tag_obj);
            if (commit_oid != null) {
                var commit = git_repo.lookupCommit(commit_oid.?) catch null;
                if (commit) |*commit_obj| {
                    defer commit_obj.free();
                    // If no tagger info, use commit info
                    if (timestamp_to_use == 0) {
                        timestamp_to_use = commit_obj.time();
                        const author = commit_obj.author();
                        author_name_to_use = try ctx.allocator.dupe(u8, std.mem.span(author.name));
                    }
                    // If no tag message, use commit message
                    if (message_to_use.len == 0) {
                        message_to_use = try ctx.allocator.dupe(u8, commit_obj.message());
                    }
                }
            }
        } else {
            // Lightweight tag - get commit info
            var commit = git_repo.lookupCommit(target_oid) catch continue;
            defer commit.free();

            message_to_use = try ctx.allocator.dupe(u8, commit.message());
            const author = commit.author();
            author_name_to_use = try ctx.allocator.dupe(u8, std.mem.span(author.name));
            timestamp_to_use = commit.time();
        }

        const oid_str = try git.oidToString(target_oid);
        var oid_buf: [40]u8 = undefined;
        @memcpy(&oid_buf, oid_str[0..40]);

        try tag_list.append(ctx.allocator, TagInfo{
            .name = try ctx.allocator.dupe(u8, std.mem.span(tag_name)),
            .oid_str = oid_buf,
            .author_name = author_name_to_use,
            .message = message_to_use,
            .timestamp = timestamp_to_use,
        });
    }

    // Sort tags by timestamp (newest first)
    std.mem.sort(TagInfo, tag_list.items, {}, struct {
        fn lessThan(_: void, a: TagInfo, b: TagInfo) bool {
            return a.timestamp > b.timestamp;
        }
    }.lessThan);

    // Render all tags
    for (tag_list.items) |tag| {
        try shared.writeTagItem(ctx, writer, shared.TagItemInfo{
            .name = tag.name,
            .oid_str = tag.oid_str,
            .author_name = tag.author_name,
            .message = tag.message,
            .timestamp = tag.timestamp,
        }, "refs");
    }

    if (tag_list.items.len == 0) {
        try writer.writeAll("<p>No tags found</p>\n");
    }

    try writer.writeAll("</div>\n"); // Close refs-list
    try writer.writeAll("</div>\n"); // Close tags
}

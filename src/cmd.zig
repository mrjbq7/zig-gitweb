const std = @import("std");
const gitweb = @import("gitweb.zig");
const ui_summary = @import("ui/summary.zig");
const ui_repolist = @import("ui/repolist.zig");
const ui_tree = @import("ui/tree.zig");
const ui_commit = @import("ui/commit.zig");
const ui_diff = @import("ui/diff.zig");
const ui_log = @import("ui/log.zig");
const ui_refs = @import("ui/refs.zig");
const ui_branches = @import("ui/branches.zig");
const ui_tags = @import("ui/tags.zig");
const ui_tag = @import("ui/tag.zig");
const ui_patch = @import("ui/patch.zig");
const ui_blob = @import("ui/blob.zig");
const ui_snapshot = @import("ui/snapshot.zig");
const ui_stats = @import("ui/stats.zig");
const ui_blame = @import("ui/blame.zig");
const ui_atom = @import("ui/atom.zig");
const ui_clone = @import("ui/clone.zig");
const ui_plain = @import("ui/plain.zig");
const ui_search = @import("ui/search.zig");
const ui_cache_stats = @import("ui/cache_stats.zig");

pub const CommandHandler = fn (ctx: *gitweb.Context, writer: std.io.AnyWriter) anyerror!void;

pub const Command = struct {
    name: []const u8,
    handler: CommandHandler,
    wants_repo: bool,
};

const commands = [_]Command{
    .{ .name = "about", .handler = ui_summary.about, .wants_repo = true },
    .{ .name = "atom", .handler = ui_atom.atom, .wants_repo = true },
    .{ .name = "blame", .handler = ui_blame.blame, .wants_repo = true },
    .{ .name = "blob", .handler = ui_blob.blob, .wants_repo = true },
    .{ .name = "branches", .handler = ui_branches.branches, .wants_repo = true },
    .{ .name = "cache-stats", .handler = ui_cache_stats.cacheStats, .wants_repo = false },
    .{ .name = "cache-clear", .handler = ui_cache_stats.cacheClear, .wants_repo = false },
    .{ .name = "cache-invalidate", .handler = ui_cache_stats.cacheInvalidate, .wants_repo = false },
    .{ .name = "commit", .handler = ui_commit.commit, .wants_repo = true },
    .{ .name = "diff", .handler = ui_diff.diff, .wants_repo = true },
    .{ .name = "info", .handler = ui_clone.info, .wants_repo = true },
    .{ .name = "log", .handler = ui_log.log, .wants_repo = true },
    .{ .name = "ls_cache", .handler = lsCache, .wants_repo = false },
    .{ .name = "objects", .handler = ui_clone.objects, .wants_repo = true },
    .{ .name = "patch", .handler = ui_patch.patch, .wants_repo = true },
    .{ .name = "plain", .handler = ui_plain.plain, .wants_repo = true },
    .{ .name = "rawdiff", .handler = ui_diff.rawdiff, .wants_repo = true },
    .{ .name = "refs", .handler = ui_refs.refs, .wants_repo = true },
    .{ .name = "repolist", .handler = ui_repolist.repolist, .wants_repo = false },
    .{ .name = "search", .handler = ui_search.search, .wants_repo = true },
    .{ .name = "snapshot", .handler = ui_snapshot.snapshot, .wants_repo = true },
    .{ .name = "stats", .handler = ui_stats.stats, .wants_repo = true },
    .{ .name = "summary", .handler = ui_summary.summary, .wants_repo = true },
    .{ .name = "tag", .handler = ui_tag.tag, .wants_repo = true },
    .{ .name = "tags", .handler = ui_tags.tags, .wants_repo = true },
    .{ .name = "tree", .handler = ui_tree.tree, .wants_repo = true },
};

pub fn dispatch(ctx: *gitweb.Context, writer: anytype) !void {
    // If no command is specified, default based on whether we have a repo
    var cmd = ctx.cmd;
    if (std.mem.eql(u8, cmd, "")) {
        if (ctx.repo != null) {
            cmd = "summary";
        } else {
            cmd = "repolist";
        }
    }

    if (std.mem.eql(u8, cmd, "summary")) return ui_summary.summary(ctx, writer);
    if (std.mem.eql(u8, cmd, "about")) return ui_summary.about(ctx, writer);
    if (std.mem.eql(u8, cmd, "atom")) return ui_atom.atom(ctx, writer);
    if (std.mem.eql(u8, cmd, "blame")) return ui_blame.blame(ctx, writer);
    if (std.mem.eql(u8, cmd, "blob")) return ui_blob.blob(ctx, writer);
    if (std.mem.eql(u8, cmd, "branches")) return ui_branches.branches(ctx, writer);
    if (std.mem.eql(u8, cmd, "commit")) return ui_commit.commit(ctx, writer);
    if (std.mem.eql(u8, cmd, "diff")) return ui_diff.diff(ctx, writer);
    if (std.mem.eql(u8, cmd, "info")) return ui_clone.info(ctx, writer);
    if (std.mem.eql(u8, cmd, "log")) return ui_log.log(ctx, writer);
    if (std.mem.eql(u8, cmd, "ls_cache")) return lsCache(ctx, writer);
    if (std.mem.eql(u8, cmd, "objects")) return ui_clone.objects(ctx, writer);
    if (std.mem.eql(u8, cmd, "patch")) return ui_patch.patch(ctx, writer);
    if (std.mem.eql(u8, cmd, "plain")) return ui_plain.plain(ctx, writer);
    if (std.mem.eql(u8, cmd, "rawdiff")) return ui_diff.rawdiff(ctx, writer);
    if (std.mem.eql(u8, cmd, "refs")) return ui_refs.refs(ctx, writer);
    if (std.mem.eql(u8, cmd, "repolist")) return ui_repolist.repolist(ctx, writer);
    if (std.mem.eql(u8, cmd, "search")) return ui_search.search(ctx, writer);
    if (std.mem.eql(u8, cmd, "snapshot")) return ui_snapshot.snapshot(ctx, writer);
    if (std.mem.eql(u8, cmd, "stats")) return ui_stats.stats(ctx, writer);
    if (std.mem.eql(u8, cmd, "tag")) return ui_tag.tag(ctx, writer);
    if (std.mem.eql(u8, cmd, "tags")) return ui_tags.tags(ctx, writer);
    if (std.mem.eql(u8, cmd, "tree")) return ui_tree.tree(ctx, writer);

    // If still no match, default to repolist or summary
    if (ctx.repo != null) {
        return ui_summary.summary(ctx, writer);
    } else {
        return ui_repolist.repolist(ctx, writer);
    }
}

pub fn wantsRepo(cmd: []const u8) bool {
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, cmd)) {
            return command.wants_repo;
        }
    }
    return true; // Default to requiring repo
}

fn lsCache(ctx: *gitweb.Context, writer: anytype) !void {
    // List cache contents (admin function)
    _ = ctx;
    try writer.writeAll("<h2>Cache Contents</h2>\n");
    try writer.writeAll("<p>Cache listing not yet implemented.</p>\n");
}

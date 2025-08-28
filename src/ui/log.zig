const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn log(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    
    try writer.writeAll("<div class='log'>\n");
    try writer.writeAll("<h2>Commit Log</h2>\n");
    
    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();
    
    // Get starting point
    const ref_name = ctx.query.get("h") orelse "HEAD";
    const path = ctx.query.get("path");
    const offset_str = ctx.query.get("ofs") orelse "0";
    const offset = std.fmt.parseInt(u32, offset_str, 10) catch 0;
    
    // Create revision walker
    var walk = try git_repo.revwalk();
    defer walk.free();
    
    // Set starting point
    if (std.mem.eql(u8, ref_name, "HEAD")) {
        try walk.pushHead();
    } else {
        try walk.pushRef(ref_name);
    }
    
    // Set sorting
    walk.setSorting(@intCast(c.GIT_SORT_TIME | if (ctx.repo.?.commit_sort == .topo) c.GIT_SORT_TOPOLOGICAL else 0));
    
    // Table headers
    if (ctx.cfg.enable_log_filecount and ctx.cfg.enable_log_linecount) {
        const headers = [_][]const u8{ "Age", "Commit", "Author", "Files", "Lines", "Message" };
        try html.writeTableHeader(writer, &headers);
    } else if (ctx.cfg.enable_log_filecount) {
        const headers = [_][]const u8{ "Age", "Commit", "Author", "Files", "Message" };
        try html.writeTableHeader(writer, &headers);
    } else {
        const headers = [_][]const u8{ "Age", "Commit", "Author", "Message" };
        try html.writeTableHeader(writer, &headers);
    }
    
    // Skip to offset
    var skip = offset;
    while (skip > 0) : (skip -= 1) {
        _ = walk.next() orelse break;
    }
    
    // Display commits
    var count: u32 = 0;
    var total: u32 = offset;
    
    while (walk.next()) |oid| {
        if (count >= ctx.cfg.max_commit_count) break;
        
        var commit = try git_repo.lookupCommit(&oid);
        defer commit.free();
        
        // If path filter is specified, check if commit touches the path
        if (path) |filter_path| {
            if (!try commitTouchesPath(&git_repo, &commit, filter_path)) {
                continue;
            }
        }
        
        count += 1;
        total += 1;
        
        const oid_str = try git.oidToString(commit.id());
        const author_sig = commit.author();
        const commit_time = commit.time();
        const summary = commit.summary();
        
        try html.writeTableRow(writer, if (count % 2 == 0) "even" else null);
        
        // Age
        try writer.writeAll("<td class='age' data-timestamp='");
        try writer.print("{d}", .{commit_time});
        try writer.writeAll("'>");
        try shared.formatAge(writer, commit_time);
        try writer.writeAll("</td>");
        
        // Commit hash
        try writer.writeAll("<td class='commit-hash'>");
        try shared.writeCommitLink(ctx, writer, &oid_str, oid_str[0..7]);
        try writer.writeAll("</td>");
        
        // Author
        try writer.writeAll("<td>");
        const author_name = std.mem.span(author_sig.name);
        const truncated_author = parsing.truncateString(author_name, 30);
        try html.htmlEscape(writer, truncated_author);
        try writer.writeAll("</td>");
        
        // File/line statistics
        if (ctx.cfg.enable_log_filecount or ctx.cfg.enable_log_linecount) {
            const stats = try getCommitStats(&git_repo, &commit);
            
            if (ctx.cfg.enable_log_filecount) {
                try writer.print("<td>{d}</td>", .{stats.files_changed});
            }
            
            if (ctx.cfg.enable_log_linecount) {
                try writer.writeAll("<td>");
                try writer.print("<span style='color: green'>+{d}</span> ", .{stats.insertions});
                try writer.print("<span style='color: red'>-{d}</span>", .{stats.deletions});
                try writer.writeAll("</td>");
            }
        }
        
        // Message
        try writer.writeAll("<td>");
        const truncated = parsing.truncateString(summary, @intCast(ctx.cfg.max_msg_len));
        try html.htmlEscape(writer, truncated);
        try writer.writeAll("</td>");
        
        try writer.writeAll("</tr>\n");
    }
    
    try html.writeTableFooter(writer);
    
    // Pagination
    try writer.writeAll("<div class='pagination'>\n");
    
    if (offset > 0) {
        const prev_offset = if (offset > ctx.cfg.max_commit_count) offset - ctx.cfg.max_commit_count else 0;
        try writer.print("<a href='?cmd=log&h={s}&ofs={d}'>← Previous</a> ", .{ ref_name, prev_offset });
    }
    
    if (count == ctx.cfg.max_commit_count) {
        try writer.print("<a href='?cmd=log&h={s}&ofs={d}'>Next →</a>", .{ ref_name, total });
    }
    
    try writer.writeAll("</div>\n");
    try writer.writeAll("</div>\n");
}

fn commitTouchesPath(repo: *git.Repository, commit: *git.Commit, path: []const u8) !bool {
    // Get commit tree
    var tree = try commit.tree();
    defer tree.free();
    
    // Check if path exists in this commit
    var path_parts = std.mem.tokenizeAny(u8, path, "/");
    var current_tree = tree;
    
    while (path_parts.next()) |part| {
        const entry = current_tree.entryByName(part);
        if (entry == null) {
            if (&current_tree != &tree) current_tree.free();
            return false;
        }
        
        if (path_parts.peek() != null) {
            if (c.git_tree_entry_type(@ptrCast(entry)) == c.GIT_OBJECT_TREE) {
                const tree_oid = c.git_tree_entry_id(@ptrCast(entry));
                const new_tree = try repo.lookupTree(@constCast(tree_oid));
                if (&current_tree != &tree) {
                    current_tree.free();
                }
                current_tree = new_tree;
            } else {
                if (&current_tree != &tree) current_tree.free();
                return false;
            }
        }
    }
    
    if (&current_tree != &tree) current_tree.free();
    
    // TODO: Check parent commits to see if path changed
    return true;
}

const CommitStats = struct {
    files_changed: usize,
    insertions: usize,
    deletions: usize,
};

fn getCommitStats(repo: *git.Repository, commit: *git.Commit) !CommitStats {
    var stats: CommitStats = undefined;
    stats.files_changed = 0;
    stats.insertions = 0;
    stats.deletions = 0;
    
    // Get parent commit
    if (commit.parentCount() == 0) {
        // Initial commit - compare against empty tree
        var tree = try commit.tree();
        defer tree.free();
        
        var diff = try git.Diff.treeToTree(repo.repo, null, tree.tree, null);
        defer diff.free();
        
        var diff_stats = try diff.getStats();
        defer diff_stats.free();
        
        stats.files_changed = @as(usize, diff_stats.filesChanged());
        stats.insertions = @as(usize, diff_stats.insertions());
        stats.deletions = @as(usize, diff_stats.deletions());
    } else {
        // Normal commit - compare against first parent
        var parent = try commit.parent(0);
        defer parent.free();
        
        var parent_tree = try parent.tree();
        defer parent_tree.free();
        
        var commit_tree = try commit.tree();
        defer commit_tree.free();
        
        var diff = try git.Diff.treeToTree(repo.repo, parent_tree.tree, commit_tree.tree, null);
        defer diff.free();
        
        var diff_stats = try diff.getStats();
        defer diff_stats.free();
        
        stats.files_changed = @as(usize, diff_stats.filesChanged());
        stats.insertions = @as(usize, diff_stats.insertions());
        stats.deletions = @as(usize, diff_stats.deletions());
    }
    
    return stats;
}
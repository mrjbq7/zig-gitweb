const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const shared = @import("shared.zig");
const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

pub fn summary(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    
    try writer.writeAll("<div class='summary'>\n");
    try writer.print("<h2>{s}</h2>\n", .{repo.name});
    
    if (repo.desc.len > 0) {
        try writer.writeAll("<div class='desc'>");
        try html.htmlEscape(writer, repo.desc);
        try writer.writeAll("</div>\n");
    }
    
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
    try writer.writeAll("<h3>Recent Commits</h3>\n");
    
    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        return;
    };
    defer git_repo.close();
    
    var walk = try git_repo.revwalk();
    defer walk.free();
    
    try walk.pushHead();
    walk.setSorting(@import("../git.zig").c.GIT_SORT_TIME);
    
    try html.writeTableHeader(writer, &[_][]const u8{ "Age", "Commit", "Author", "Message" });
    
    var count: u32 = 0;
    while (walk.next()) |oid| {
        if (count >= ctx.cfg.summary_log) break;
        count += 1;
        
        var commit = try git_repo.lookupCommit(&oid);
        defer commit.free();
        
        const oid_str = try git.oidToString(commit.id());
        const author_sig = commit.author();
        const commit_time = commit.time();
        
        try html.writeTableRow(writer, null);
        
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
        try html.htmlEscape(writer, std.mem.span(author_sig.name));
        try writer.writeAll("</td>");
        
        // Message
        try writer.writeAll("<td>");
        const commit_summary = commit.summary();
        const truncated = parsing.truncateString(commit_summary, @intCast(ctx.cfg.max_msg_len));
        try html.htmlEscape(writer, truncated);
        try writer.writeAll("</td>");
        
        try writer.writeAll("</tr>\n");
    }
    
    try html.writeTableFooter(writer);
}

fn showBranches(ctx: *gitweb.Context, repo: *gitweb.Repo, writer: anytype) !void {
    try writer.writeAll("<h3>Branches</h3>\n");
    
    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        return;
    };
    defer git_repo.close();
    
    const branches = try git_repo.getBranches(ctx.allocator);
    defer ctx.allocator.free(branches);
    
    if (branches.len == 0) {
        try writer.writeAll("<p>No branches found.</p>\n");
        return;
    }
    
    try html.writeTableHeader(writer, &[_][]const u8{ "Branch", "Commit", "Author", "Age" });
    
    var shown: u32 = 0;
    for (branches) |branch| {
        if (!branch.is_remote and shown < ctx.cfg.summary_branches) {
            shown += 1;
            defer @constCast(&branch.ref).free();
            
            const target = @constCast(&branch.ref).target() orelse continue;
            var commit = try git_repo.lookupCommit(target);
            defer commit.free();
            
            const oid_str = try git.oidToString(commit.id());
            const author_sig = commit.author();
            const commit_time = commit.time();
            
            try html.writeTableRow(writer, null);
            
            // Branch name
            try writer.writeAll("<td>");
            try writer.print("<a href='?cmd=log&h={s}'>{s}</a>", .{ branch.name, branch.name });
            try writer.writeAll("</td>");
            
            // Commit
            try writer.writeAll("<td>");
            try shared.writeCommitLink(ctx, writer, &oid_str, oid_str[0..7]);
            try writer.writeAll("</td>");
            
            // Author
            try writer.writeAll("<td>");
            try html.htmlEscape(writer, std.mem.span(author_sig.name));
            try writer.writeAll("</td>");
            
            // Age
            try writer.writeAll("<td class='age' data-timestamp='");
            try writer.print("{d}", .{commit_time});
            try writer.writeAll("'>");
            try shared.formatAge(writer, commit_time);
            try writer.writeAll("</td>");
            
            try writer.writeAll("</tr>\n");
        }
    }
    
    try html.writeTableFooter(writer);
}

fn showTags(ctx: *gitweb.Context, repo: *gitweb.Repo, writer: anytype) !void {
    try writer.writeAll("<h3>Tags</h3>\n");
    
    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
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
        return;
    }
    
    try html.writeTableHeader(writer, &[_][]const u8{ "Tag", "Download", "Author", "Age" });
    
    var shown: u32 = 0;
    for (tags) |tag| {
        if (shown >= ctx.cfg.summary_tags) break;
        shown += 1;
        defer @constCast(&tag.ref).free();
        
        _ = @constCast(&tag.ref).target() orelse continue;
        
        // Try to get tag object or fall back to commit
        var obj = @constCast(&tag.ref).peel(@import("../git.zig").c.GIT_OBJECT_COMMIT) catch continue;
        defer obj.free();
        
        var commit = try git_repo.lookupCommit(obj.id());
        defer commit.free();
        
        const author_sig = commit.author();
        const commit_time = commit.time();
        
        try html.writeTableRow(writer, null);
        
        // Tag name
        try writer.writeAll("<td>");
        try writer.print("<a href='?cmd=tag&id={s}'>{s}</a>", .{ tag.name, tag.name });
        try writer.writeAll("</td>");
        
        // Download links
        try writer.writeAll("<td>");
        try writer.print("<a href='?cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> ", .{tag.name});
        try writer.print("<a href='?cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{tag.name});
        try writer.writeAll("</td>");
        
        // Author
        try writer.writeAll("<td>");
        try html.htmlEscape(writer, std.mem.span(author_sig.name));
        try writer.writeAll("</td>");
        
        // Age
        try writer.writeAll("<td class='age' data-timestamp='");
        try writer.print("{d}", .{commit_time});
        try writer.writeAll("'>");
        try shared.formatAge(writer, commit_time);
        try writer.writeAll("</td>");
        
        try writer.writeAll("</tr>\n");
    }
    
    try html.writeTableFooter(writer);
}

pub fn about(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    
    try writer.writeAll("<div class='about'>\n");
    try writer.print("<h2>About {s}</h2>\n", .{repo.name});
    
    // TODO: Read and render README file
    try writer.writeAll("<p>README content will be shown here.</p>\n");
    
    try writer.writeAll("</div>\n");
}
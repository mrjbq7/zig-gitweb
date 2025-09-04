const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");
const git = @import("../git.zig");
const shared = @import("shared.zig");
const parsing = @import("../parsing.zig");

const c = git.c;

pub fn search(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;

    try writer.writeAll("<div class='search'>\n");

    const search_term = ctx.query.get("q") orelse {
        try renderSearchForm(ctx, writer);
        try writer.writeAll("</div>\n");
        return;
    };

    const search_type = ctx.query.get("type") orelse "commit";

    // Show search form at top
    try renderSearchForm(ctx, writer);

    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return;
    };
    defer git_repo.close();

    // Perform search based on type
    if (std.mem.eql(u8, search_type, "commit")) {
        try searchCommits(ctx, &git_repo, search_term, writer);
    } else if (std.mem.eql(u8, search_type, "author")) {
        try searchAuthor(ctx, &git_repo, search_term, writer);
    } else if (std.mem.eql(u8, search_type, "grep")) {
        try searchGrep(ctx, &git_repo, search_term, writer);
    } else if (std.mem.eql(u8, search_type, "pickaxe")) {
        try searchPickaxe(ctx, &git_repo, search_term, writer);
    } else {
        try writer.writeAll("<p>Invalid search type.</p>\n");
    }

    try writer.writeAll("</div>\n");
}

fn renderSearchForm(ctx: *gitweb.Context, writer: anytype) !void {
    const search_term = ctx.query.get("q") orelse "";
    const search_type = ctx.query.get("type") orelse "commit";
    const branch = ctx.query.get("h");

    try writer.writeAll("<form method='get' action='' class='search-form'>\n");

    // Hidden repo parameter
    if (ctx.repo) |r| {
        try writer.print("<input type='hidden' name='r' value='{s}' />\n", .{r.name});
    }
    try writer.writeAll("<input type='hidden' name='cmd' value='search' />\n");

    // Hidden branch parameter
    if (branch) |h| {
        try writer.print("<input type='hidden' name='h' value='{s}' />\n", .{h});
    }

    // Search input
    try writer.writeAll("<div class='search-input'>\n");
    try writer.print("<input type='text' name='q' value='{s}' placeholder='Search term' />\n", .{search_term});

    // Search type selector
    try writer.writeAll("<select name='type'>\n");
    try writeSearchOption(writer, "commit", "Commits", search_type);
    try writeSearchOption(writer, "author", "Authors", search_type);
    try writeSearchOption(writer, "grep", "Files", search_type);
    try writeSearchOption(writer, "pickaxe", "Changes", search_type);
    try writer.writeAll("</select>\n");

    try writer.writeAll("<button type='submit' class='btn'>Search</button>\n");
    try writer.writeAll("</div>\n");
    try writer.writeAll("</form>\n");
}

fn writeSearchOption(writer: anytype, value: []const u8, label: []const u8, current: []const u8) !void {
    if (std.mem.eql(u8, value, current)) {
        try writer.print("<option value='{s}' selected>{s}</option>\n", .{ value, label });
    } else {
        try writer.print("<option value='{s}'>{s}</option>\n", .{ value, label });
    }
}

fn searchCommits(ctx: *gitweb.Context, repo: *git.Repository, search_term: []const u8, writer: anytype) !void {
    try writer.writeAll("<h3>Commits</h3>\n");
    try writer.writeAll("<p class='search-description'>Showing commits with messages containing '<strong>");
    try html.htmlEscape(writer, search_term);
    try writer.writeAll("</strong>':</p>\n");

    var walk = try repo.revwalk();
    defer walk.free();

    // Handle branch filtering like stats
    const ref_name = ctx.query.get("h") orelse "HEAD";
    if (std.mem.eql(u8, ref_name, "HEAD")) {
        try walk.pushHead();
    } else {
        // Try to get the reference
        var ref = repo.getReference(ref_name) catch {
            const full_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_name}, 0);
            defer ctx.allocator.free(full_ref);

            var ref2 = repo.getReference(full_ref) catch {
                try walk.pushHead();
                walk.setSorting(c.GIT_SORT_NONE);
                return searchCommitsFromWalk(ctx, repo, &walk, search_term, writer);
            };
            defer ref2.free();

            const oid = ref2.target() orelse {
                try walk.pushHead();
                walk.setSorting(c.GIT_SORT_NONE);
                return searchCommitsFromWalk(ctx, repo, &walk, search_term, writer);
            };
            _ = c.git_revwalk_push(walk.walk, oid);
            walk.setSorting(c.GIT_SORT_NONE);
            return searchCommitsFromWalk(ctx, repo, &walk, search_term, writer);
        };
        defer ref.free();

        const oid = ref.target() orelse {
            try walk.pushHead();
            walk.setSorting(c.GIT_SORT_NONE);
            return searchCommitsFromWalk(ctx, repo, &walk, search_term, writer);
        };
        _ = c.git_revwalk_push(walk.walk, oid);
    }

    walk.setSorting(c.GIT_SORT_NONE);
    return searchCommitsFromWalk(ctx, repo, &walk, search_term, writer);
}

fn searchCommitsFromWalk(ctx: *gitweb.Context, repo: *git.Repository, walk: *git.RevWalk, search_term: []const u8, writer: anytype) !void {
    var found_count: usize = 0;
    const max_results = 100;

    // Convert search term to lowercase for case-insensitive search
    const search_lower = try std.ascii.allocLowerString(ctx.allocator, search_term);
    defer ctx.allocator.free(search_lower);

    try writer.writeAll("<div class='log-list'>\n");

    while (walk.next()) |oid| {
        if (found_count >= max_results) break;

        var commit = try repo.lookupCommit(&oid);
        defer commit.free();

        const message = commit.message();

        // Convert message to lowercase for comparison
        const message_lower = try std.ascii.allocLowerString(ctx.allocator, message);
        defer ctx.allocator.free(message_lower);

        // Check if search term is in the commit message
        if (std.mem.indexOf(u8, message_lower, search_lower) != null) {
            try renderSearchResult(ctx, &commit, &oid, message, writer);
            found_count += 1;
        }
    }

    try writer.writeAll("</div>\n");

    if (found_count == 0) {
        try writer.writeAll("<p>No commits found containing the search term.</p>\n");
    } else if (found_count >= max_results) {
        try writer.print("<p>Showing first {d} results. Refine your search for more specific results.</p>\n", .{max_results});
    } else {
        try writer.print("<p>Found {d} matching commits.</p>\n", .{found_count});
    }
}

fn searchAuthor(ctx: *gitweb.Context, repo: *git.Repository, search_term: []const u8, writer: anytype) !void {
    try writer.writeAll("<h3>Authors</h3>\n");
    try writer.writeAll("<p class='search-description'>Showing commits by authors matching '<strong>");
    try html.htmlEscape(writer, search_term);
    try writer.writeAll("</strong>':</p>\n");

    var walk = try repo.revwalk();
    defer walk.free();

    // Handle branch filtering like commit search
    const ref_name = ctx.query.get("h") orelse "HEAD";
    if (std.mem.eql(u8, ref_name, "HEAD")) {
        try walk.pushHead();
    } else {
        // Try to get the reference
        var ref = repo.getReference(ref_name) catch {
            const full_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_name}, 0);
            defer ctx.allocator.free(full_ref);

            var ref2 = repo.getReference(full_ref) catch {
                try walk.pushHead();
                walk.setSorting(c.GIT_SORT_NONE);
                return searchAuthorFromWalk(ctx, repo, &walk, search_term, writer);
            };
            defer ref2.free();

            const oid = ref2.target() orelse {
                try walk.pushHead();
                walk.setSorting(c.GIT_SORT_NONE);
                return searchAuthorFromWalk(ctx, repo, &walk, search_term, writer);
            };
            _ = c.git_revwalk_push(walk.walk, oid);
            walk.setSorting(c.GIT_SORT_NONE);
            return searchAuthorFromWalk(ctx, repo, &walk, search_term, writer);
        };
        defer ref.free();

        const oid = ref.target() orelse {
            try walk.pushHead();
            walk.setSorting(c.GIT_SORT_NONE);
            return searchAuthorFromWalk(ctx, repo, &walk, search_term, writer);
        };
        _ = c.git_revwalk_push(walk.walk, oid);
    }

    walk.setSorting(c.GIT_SORT_NONE);
    return searchAuthorFromWalk(ctx, repo, &walk, search_term, writer);
}

fn searchAuthorFromWalk(ctx: *gitweb.Context, repo: *git.Repository, walk: *git.RevWalk, search_term: []const u8, writer: anytype) !void {
    var found_count: usize = 0;
    const max_results = 100;

    const search_lower = try std.ascii.allocLowerString(ctx.allocator, search_term);
    defer ctx.allocator.free(search_lower);

    try writer.writeAll("<div class='log-list'>\n");

    while (walk.next()) |oid| {
        if (found_count >= max_results) break;

        var commit = try repo.lookupCommit(&oid);
        defer commit.free();

        const author_sig = commit.author();
        const author_name = std.mem.span(author_sig.name);
        const author_email = if (author_sig.email) |email| std.mem.span(email) else "";

        const author_name_lower = try std.ascii.allocLowerString(ctx.allocator, author_name);
        defer ctx.allocator.free(author_name_lower);

        const author_email_lower = try std.ascii.allocLowerString(ctx.allocator, author_email);
        defer ctx.allocator.free(author_email_lower);

        // Check if search term matches either name or email
        const name_match = std.mem.indexOf(u8, author_name_lower, search_lower) != null;
        const email_match = std.mem.indexOf(u8, author_email_lower, search_lower) != null;

        if (name_match or email_match) {
            const message = commit.message();
            try renderSearchResult(ctx, &commit, &oid, message, writer);
            found_count += 1;
        }
    }

    try writer.writeAll("</div>\n");

    if (found_count == 0) {
        try writer.writeAll("<p>No commits found by authors matching the search term.</p>\n");
    } else if (found_count >= max_results) {
        try writer.print("<p>Showing first {d} results.</p>\n", .{max_results});
    } else {
        try writer.print("<p>Found {d} matching commits.</p>\n", .{found_count});
    }
}

fn searchGrep(ctx: *gitweb.Context, repo: *git.Repository, search_term: []const u8, writer: anytype) !void {
    try writer.writeAll("<h3>Files</h3>\n");
    try writer.writeAll("<p class='search-description'>Showing files containing '<strong>");
    try html.htmlEscape(writer, search_term);
    try writer.writeAll("</strong>':</p>\n");

    // Get commit based on branch parameter
    const ref_name = ctx.query.get("h") orelse "HEAD";
    var commit = blk: {
        if (std.mem.eql(u8, ref_name, "HEAD")) {
            var head_ref = try repo.getHead();
            defer head_ref.free();

            const head_oid = head_ref.target() orelse {
                try writer.writeAll("<p>Unable to get HEAD commit.</p>\n");
                return;
            };

            break :blk try repo.lookupCommit(head_oid);
        } else {
            // Try to get the reference
            var ref = repo.getReference(ref_name) catch {
                const full_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_name}, 0);
                defer ctx.allocator.free(full_ref);

                var ref2 = repo.getReference(full_ref) catch {
                    try writer.writeAll("<p>Unable to find branch reference.</p>\n");
                    return;
                };
                defer ref2.free();

                const oid = ref2.target() orelse {
                    try writer.writeAll("<p>Unable to get branch commit.</p>\n");
                    return;
                };
                break :blk try repo.lookupCommit(oid);
            };
            defer ref.free();

            const oid = ref.target() orelse {
                try writer.writeAll("<p>Unable to get branch commit.</p>\n");
                return;
            };
            break :blk try repo.lookupCommit(oid);
        }
    };
    defer commit.free();

    var tree = try commit.tree();
    defer tree.free();

    var found_count: usize = 0;
    const max_results = 100;

    try searchTreeContents(ctx, repo, &tree, "", search_term, &found_count, max_results, writer);

    if (found_count == 0) {
        try writer.writeAll("<p>No files found containing the search term.</p>\n");
    } else if (found_count >= max_results) {
        try writer.print("<p>Showing first {d} results.</p>\n", .{max_results});
    } else {
        try writer.print("<p>Found {d} matching lines.</p>\n", .{found_count});
    }
}

const GrepMatch = struct {
    line_num: usize,
    content: []const u8,
};

fn searchTreeContents(ctx: *gitweb.Context, repo: *git.Repository, tree: *git.Tree, path_prefix: []const u8, search_term: []const u8, found_count: *usize, max_results: usize, writer: anytype) !void {
    if (found_count.* >= max_results) return;

    const search_lower = try std.ascii.allocLowerString(ctx.allocator, search_term);
    defer ctx.allocator.free(search_lower);

    const entry_count = tree.entryCount();
    for (0..entry_count) |i| {
        if (found_count.* >= max_results) break;

        const entry = tree.entryByIndex(i) orelse continue;
        const entry_name = std.mem.span(c.git_tree_entry_name(entry));
        const entry_type = c.git_tree_entry_type(entry);

        const full_path = if (path_prefix.len > 0)
            try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ path_prefix, entry_name })
        else
            try ctx.allocator.dupe(u8, entry_name);
        defer ctx.allocator.free(full_path);

        if (entry_type == c.GIT_OBJECT_BLOB) {
            // Search in blob content
            const blob_oid = c.git_tree_entry_id(entry);
            var blob = try repo.lookupBlob(@constCast(blob_oid));
            defer blob.free();

            const content = blob.content();

            // Skip binary files
            if (blob.isBinary()) continue;

            // Collect matching lines for this file
            var matching_lines = std.ArrayList(GrepMatch).empty;
            defer matching_lines.deinit(ctx.allocator);

            // Search line by line
            var lines = std.mem.splitScalar(u8, content, '\n');
            var line_num: usize = 1;

            while (lines.next()) |line| {
                const line_lower = try std.ascii.allocLowerString(ctx.allocator, line);
                defer ctx.allocator.free(line_lower);

                if (std.mem.indexOf(u8, line_lower, search_lower) != null) {
                    try matching_lines.append(ctx.allocator, GrepMatch{ .line_num = line_num, .content = line });
                    if (found_count.* + matching_lines.items.len >= max_results) break;
                }
                line_num += 1;
            }

            // If we found matches in this file, render them as a group
            if (matching_lines.items.len > 0) {
                try renderGrepFileResults(ctx, full_path, matching_lines.items, writer);
                found_count.* += matching_lines.items.len;
            }
        } else if (entry_type == c.GIT_OBJECT_TREE) {
            // Recursively search subdirectories
            const sub_tree_oid = c.git_tree_entry_id(entry);
            var sub_tree = try repo.lookupTree(@constCast(sub_tree_oid));
            defer sub_tree.free();

            try searchTreeContents(ctx, repo, &sub_tree, full_path, search_term, found_count, max_results, writer);
        }
    }
}

fn renderSearchResult(ctx: *gitweb.Context, commit: *git.Commit, oid: *const c.git_oid, message: []const u8, writer: anytype) !void {
    const author_sig = commit.author();
    const author_name = std.mem.span(author_sig.name);
    const commit_time = commit.time();

    const oid_str = try git.oidToString(oid);
    const parsed_msg = parsing.parseCommitMessage(message);

    // Use the shared commit item format
    var oid_arr: [40]u8 = undefined;
    _ = try std.fmt.bufPrint(&oid_arr, "{s}", .{oid_str});

    const commit_info = shared.CommitItemInfo{
        .oid_str = oid_arr,
        .message = parsed_msg.subject,
        .author_name = author_name,
        .timestamp = commit_time,
    };

    try shared.writeCommitItem(ctx, writer, commit_info, "log");
}

fn searchPickaxe(ctx: *gitweb.Context, repo: *git.Repository, search_term: []const u8, writer: anytype) !void {
    try writer.writeAll("<h3>Changes</h3>\n");
    try writer.writeAll("<p class='search-description'>Showing commits where '<strong>");
    try html.htmlEscape(writer, search_term);
    try writer.writeAll("</strong>' was added or removed:</p>\n");

    var walk = try repo.revwalk();
    defer walk.free();

    // Handle branch filtering
    const ref_name = ctx.query.get("h") orelse "HEAD";
    if (std.mem.eql(u8, ref_name, "HEAD")) {
        try walk.pushHead();
    } else {
        var ref = shared.resolveReference(ctx, repo, ref_name) catch {
            try walk.pushHead();
            walk.setSorting(c.GIT_SORT_NONE);
            return searchPickaxeFromWalk(ctx, repo, &walk, search_term, writer);
        };
        defer @constCast(&ref).free();

        const oid = @constCast(&ref).target() orelse {
            try walk.pushHead();
            walk.setSorting(c.GIT_SORT_NONE);
            return searchPickaxeFromWalk(ctx, repo, &walk, search_term, writer);
        };
        _ = c.git_revwalk_push(walk.walk, oid);
    }

    walk.setSorting(c.GIT_SORT_NONE);
    return searchPickaxeFromWalk(ctx, repo, &walk, search_term, writer);
}

fn searchPickaxeFromWalk(ctx: *gitweb.Context, repo: *git.Repository, walk: *git.RevWalk, search_term: []const u8, writer: anytype) !void {
    var found_count: usize = 0;
    const max_results = 50;

    try writer.writeAll("<table class='search-results'>\n");
    try writer.writeAll("<tr><th>Commit</th><th>File</th><th>Change</th><th>Line</th></tr>\n");

    while (walk.next()) |oid| {
        if (found_count >= max_results) break;

        var commit = try repo.lookupCommit(&oid);
        defer commit.free();

        // Get parent if exists
        const parent_tree = if (commit.parentCount() > 0) blk: {
            var parent = try commit.parent(0);
            defer parent.free();
            const tree = try parent.tree();
            break :blk tree;
        } else null;
        defer if (parent_tree) |*t| @constCast(t).free();

        // Get current commit's tree
        var commit_tree = try commit.tree();
        defer commit_tree.free();

        // Collect matching changes
        var matches = std.ArrayList(PickaxeMatch).empty;
        defer {
            for (matches.items) |*match| {
                ctx.allocator.free(match.file_path);
                for (match.lines.items) |*line| {
                    ctx.allocator.free(line.content);
                }
                match.lines.deinit(ctx.allocator);
            }
            matches.deinit(ctx.allocator);
        }

        if (parent_tree) |*pt| {
            try collectPickaxeMatches(ctx, repo, @constCast(pt), &commit_tree, search_term, &matches);
        } else {
            try collectInitialMatches(ctx, repo, &commit_tree, search_term, &matches);
        }

        if (matches.items.len > 0) {
            for (matches.items) |*match| {
                try renderPickaxeMatch(ctx, &commit, &oid, match, writer);
                found_count += 1;
                if (found_count >= max_results) break;
            }
        }
    }

    try writer.writeAll("</table>\n");

    if (found_count == 0) {
        try writer.writeAll("<p>No commits found that add or remove the search term.</p>\n");
    } else if (found_count >= max_results) {
        try writer.print("<p>Showing first {d} results.</p>\n", .{max_results});
    } else {
        try writer.print("<p>Found {d} commits with changes.</p>\n", .{found_count});
    }
}

const PickaxeMatch = struct {
    file_path: []const u8,
    lines: std.ArrayList(MatchLine),
};

const MatchLine = struct {
    line_num: usize,
    content: []const u8,
    is_addition: bool,
};

fn collectPickaxeMatches(ctx: *gitweb.Context, repo: *git.Repository, old_tree: *git.Tree, new_tree: *git.Tree, search_term: []const u8, matches: *std.ArrayList(PickaxeMatch)) !void {
    // Get diff between trees
    var diff = try git.Diff.treeToTree(repo.repo, old_tree.tree, new_tree.tree, null);
    defer diff.free();

    // Check each file in the diff
    const num_deltas = diff.numDeltas();
    for (0..num_deltas) |i| {
        const delta = diff.getDelta(i) orelse continue;

        const file_path = if (delta.new_file.path) |p| std.mem.span(p) else if (delta.old_file.path) |p| std.mem.span(p) else continue;

        // Get old file content
        const old_count = if (delta.old_file.id.id[0] != 0) blk: {
            var old_blob = repo.lookupBlob(&delta.old_file.id) catch break :blk 0;
            defer old_blob.free();
            if (old_blob.isBinary()) break :blk 0;
            break :blk countOccurrences(old_blob.content(), search_term);
        } else 0;

        // Get new file content
        const new_count = if (delta.new_file.id.id[0] != 0) blk: {
            var new_blob = repo.lookupBlob(&delta.new_file.id) catch break :blk 0;
            defer new_blob.free();
            if (new_blob.isBinary()) break :blk 0;
            break :blk countOccurrences(new_blob.content(), search_term);
        } else 0;

        // Check if occurrence count changed
        if (old_count != new_count) {
            var match_lines = std.ArrayList(MatchLine).empty;

            // Find lines that were added or removed - now we need to re-open the blob to get content
            if (new_count > old_count) {
                // Term was added - find the new lines
                if (delta.new_file.id.id[0] != 0) {
                    var new_blob = repo.lookupBlob(&delta.new_file.id) catch continue;
                    defer new_blob.free();
                    if (!new_blob.isBinary()) {
                        const content = new_blob.content();
                        try findMatchingLines(ctx, content, search_term, true, &match_lines);
                    }
                }
            } else {
                // Term was removed - find the old lines
                if (delta.old_file.id.id[0] != 0) {
                    var old_blob = repo.lookupBlob(&delta.old_file.id) catch continue;
                    defer old_blob.free();
                    if (!old_blob.isBinary()) {
                        const content = old_blob.content();
                        try findMatchingLines(ctx, content, search_term, false, &match_lines);
                    }
                }
            }

            if (match_lines.items.len > 0) {
                const match = PickaxeMatch{
                    .file_path = try ctx.allocator.dupe(u8, file_path),
                    .lines = match_lines,
                };
                try matches.append(ctx.allocator, match);
            } else {
                match_lines.deinit(ctx.allocator);
            }
        }
    }
}

fn collectInitialMatches(ctx: *gitweb.Context, repo: *git.Repository, tree: *git.Tree, search_term: []const u8, matches: *std.ArrayList(PickaxeMatch)) !void {
    try collectInitialMatchesRecursive(ctx, repo, tree, "", search_term, matches);
}

fn collectInitialMatchesRecursive(ctx: *gitweb.Context, repo: *git.Repository, tree: *git.Tree, path_prefix: []const u8, search_term: []const u8, matches: *std.ArrayList(PickaxeMatch)) !void {
    const entry_count = tree.entryCount();
    for (0..entry_count) |i| {
        const entry = tree.entryByIndex(i) orelse continue;
        const entry_name = std.mem.span(c.git_tree_entry_name(entry));
        const entry_type = c.git_tree_entry_type(entry);

        const full_path = if (path_prefix.len > 0)
            try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ path_prefix, entry_name })
        else
            try ctx.allocator.dupe(u8, entry_name);
        defer ctx.allocator.free(full_path);

        if (entry_type == c.GIT_OBJECT_BLOB) {
            const blob_oid = c.git_tree_entry_id(entry);
            var blob = repo.lookupBlob(@constCast(blob_oid)) catch continue;
            defer blob.free();

            if (!blob.isBinary()) {
                const content = blob.content();

                if (countOccurrences(content, search_term) > 0) {
                    var match_lines = std.ArrayList(MatchLine).empty;
                    // findMatchingLines will duplicate the individual lines it finds
                    try findMatchingLines(ctx, content, search_term, true, &match_lines);

                    if (match_lines.items.len > 0) {
                        const match = PickaxeMatch{
                            .file_path = try ctx.allocator.dupe(u8, full_path),
                            .lines = match_lines,
                        };
                        try matches.append(ctx.allocator, match);
                    } else {
                        match_lines.deinit(ctx.allocator);
                    }
                }
            }
        } else if (entry_type == c.GIT_OBJECT_TREE) {
            const sub_tree_oid = c.git_tree_entry_id(entry);
            var sub_tree = repo.lookupTree(@constCast(sub_tree_oid)) catch continue;
            defer sub_tree.free();

            try collectInitialMatchesRecursive(ctx, repo, &sub_tree, full_path, search_term, matches);
        }
    }
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < haystack.len) {
        if (std.mem.indexOfPos(u8, haystack, pos, needle)) |found_pos| {
            count += 1;
            pos = found_pos + needle.len;
        } else {
            break;
        }
    }
    return count;
}

fn findMatchingLines(ctx: *gitweb.Context, content: []const u8, search_term: []const u8, is_addition: bool, match_lines: *std.ArrayList(MatchLine)) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 1;

    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, search_term) != null) {
            const match_line = MatchLine{
                .line_num = line_num,
                .content = try ctx.allocator.dupe(u8, line),
                .is_addition = is_addition,
            };
            try match_lines.append(ctx.allocator, match_line);

            // Limit to 5 matching lines per file
            if (match_lines.items.len >= 5) break;
        }
        line_num += 1;
    }
}

fn renderPickaxeMatch(ctx: *gitweb.Context, commit: *git.Commit, oid: *const c.git_oid, match: *PickaxeMatch, writer: anytype) !void {
    var oid_str: [40]u8 = undefined;
    _ = c.git_oid_fmt(&oid_str, oid);

    const message = commit.message();
    const parsed_msg = parsing.parseCommitMessage(message);

    for (match.lines.items) |*line| {
        try writer.writeAll("<tr>");

        // Commit column
        try writer.writeAll("<td>");
        try writer.writeAll("<a href='?");
        if (ctx.repo) |r| {
            try writer.print("r={s}&", .{r.name});
        }
        try writer.print("cmd=commit&id={s}' title='", .{&oid_str});
        try html.htmlEscape(writer, parsed_msg.subject);
        try writer.print("'>{s}</a>", .{oid_str[0..7]});
        try writer.writeAll("</td>");

        // File path column - linked to blob view at this commit with line number
        try writer.writeAll("<td>");
        try writer.writeAll("<a href='?");
        if (ctx.repo) |r| {
            try writer.print("r={s}&", .{r.name});
        }
        try writer.writeAll("cmd=blob&path=");
        try html.urlEncodePath(writer, match.file_path);
        try writer.print("&id={s}#L{d}'>", .{ &oid_str, line.line_num });
        try html.htmlEscape(writer, match.file_path);
        try writer.writeAll("</a>");
        try writer.writeAll("</td>");

        // Change type column
        try writer.writeAll("<td>");
        if (line.is_addition) {
            try writer.writeAll("<span style='color: green'>+</span>");
        } else {
            try writer.writeAll("<span style='color: red'>-</span>");
        }
        try writer.writeAll("</td>");

        // Line content column
        try writer.writeAll("<td><code>");
        const truncated = if (line.content.len > 100) line.content[0..97] else line.content;
        try html.htmlEscape(writer, truncated);
        if (line.content.len > 100) {
            try writer.writeAll("...");
        }
        try writer.writeAll("</code></td>");

        try writer.writeAll("</tr>\n");
    }
}

fn renderGrepFileResults(ctx: *gitweb.Context, file_path: []const u8, matches: []const GrepMatch, writer: anytype) !void {
    // File container with header
    try writer.writeAll("<div class='file-section'>\n");

    // File header
    try writer.writeAll("<div class='file-header'>\n");
    try writer.writeAll("<a href='?");
    if (ctx.repo) |r| {
        try writer.print("r={s}&", .{r.name});
    }
    try writer.writeAll("cmd=blob&path=");
    try html.urlEncodePath(writer, file_path);
    if (ctx.query.get("h")) |h| {
        try writer.print("&h={s}", .{h});
    }
    try writer.writeAll("'>");
    try writer.print("<strong>{s}</strong>", .{file_path});
    try writer.writeAll("</a>");
    try writer.print(" ({d} match{s})", .{ matches.len, if (matches.len == 1) "" else "es" });
    try writer.writeAll("</div>\n");

    // Render matches in blob style
    try writer.print("<pre class='blob' data-filename='{s}'>", .{file_path});
    try writer.writeAll("<table class='blob-content'>");

    for (matches) |match| {
        try writer.writeAll("<tr>");

        // Line number column - link to blob page at specific line
        try writer.print("<td class='linenumber' id='L{d}'><a href='?", .{match.line_num});
        if (ctx.repo) |r| {
            try writer.print("r={s}&", .{r.name});
        }
        try writer.writeAll("cmd=blob&path=");
        try html.urlEncodePath(writer, file_path);
        if (ctx.query.get("h")) |h| {
            try writer.print("&h={s}", .{h});
        }
        try writer.print("#L{d}'>{d}</a></td>", .{ match.line_num, match.line_num });

        // Code content column
        try writer.writeAll("<td class='code'>");
        try html.htmlEscape(writer, match.content);
        try writer.writeAll("</td>");

        try writer.writeAll("</tr>\n");
    }

    try writer.writeAll("</table>");
    try writer.writeAll("</pre>\n");
    try writer.writeAll("</div>\n"); // Close file-section div
}

fn renderGrepResult(ctx: *gitweb.Context, file_path: []const u8, line_num: usize, line_content: []const u8, writer: anytype) !void {
    try writer.writeAll("<tr>");

    // File path with link to blob at specific line number
    try writer.writeAll("<td>");
    try writer.writeAll("<a href='?");
    if (ctx.repo) |r| {
        try writer.print("r={s}&", .{r.name});
    }
    try writer.writeAll("cmd=blob&path=");
    try html.urlEncodePath(writer, file_path);
    if (ctx.query.get("h")) |h| {
        try writer.print("&h={s}", .{h});
    }
    try writer.print("#L{d}", .{line_num});
    try writer.writeAll("'>");
    try html.htmlEscape(writer, file_path);
    try writer.writeAll("</a>");
    try writer.writeAll("</td>");

    // Line number (also linked to the specific line)
    try writer.writeAll("<td>");
    try writer.writeAll("<a href='?");
    if (ctx.repo) |r| {
        try writer.print("r={s}&", .{r.name});
    }
    try writer.writeAll("cmd=blob&path=");
    try html.urlEncodePath(writer, file_path);
    if (ctx.query.get("h")) |h| {
        try writer.print("&h={s}", .{h});
    }
    try writer.print("#L{d}'>", .{line_num});
    try writer.print("{d}", .{line_num});
    try writer.writeAll("</a>");
    try writer.writeAll("</td>");

    // Line content (truncated if too long)
    try writer.writeAll("<td><code>");
    const truncated = if (line_content.len > 100) line_content[0..97] else line_content;
    try html.htmlEscape(writer, truncated);
    if (line_content.len > 100) {
        try writer.writeAll("...");
    }
    try writer.writeAll("</code></td>");

    try writer.writeAll("</tr>\n");
}

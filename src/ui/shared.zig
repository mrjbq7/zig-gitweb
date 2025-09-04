const std = @import("std");
const gitweb = @import("../gitweb.zig");
const html = @import("../html.zig");

pub fn formatAge(writer: anytype, timestamp: i64) !void {
    const now = std.time.timestamp();
    const diff = now - timestamp;

    if (diff < 0) {
        try writer.writeAll("<span class='age-recent'>in the future</span>");
        return;
    }

    // Determine age category for styling
    const age_class = if (diff < @as(i64, @intFromFloat(gitweb.TM_MONTH)))
        "age-recent" // black for days and weeks
    else if (diff < gitweb.TM_YEAR)
        "age-months" // gray for months
    else
        "age-years"; // light gray for years

    try writer.print("<span class='{s}'>", .{age_class});

    if (diff < gitweb.TM_MIN) {
        try writer.print("{d} seconds ago", .{diff});
    } else if (diff < gitweb.TM_HOUR) {
        const mins = @divFloor(diff, gitweb.TM_MIN);
        try writer.print("{d} minute{s} ago", .{ mins, if (mins == 1) "" else "s" });
    } else if (diff < gitweb.TM_DAY) {
        const hours = @divFloor(diff, gitweb.TM_HOUR);
        try writer.print("{d} hour{s} ago", .{ hours, if (hours == 1) "" else "s" });
    } else if (diff < gitweb.TM_WEEK) {
        const days = @divFloor(diff, gitweb.TM_DAY);
        try writer.print("{d} day{s} ago", .{ days, if (days == 1) "" else "s" });
    } else if (diff < @as(i64, @intFromFloat(gitweb.TM_MONTH))) {
        const weeks = @divFloor(diff, gitweb.TM_WEEK);
        try writer.print("{d} week{s} ago", .{ weeks, if (weeks == 1) "" else "s" });
    } else if (diff < gitweb.TM_YEAR) {
        const months = @divFloor(diff, @as(i64, @intFromFloat(gitweb.TM_MONTH)));
        try writer.print("{d} month{s} ago", .{ months, if (months == 1) "" else "s" });
    } else {
        const years = @divFloor(diff, gitweb.TM_YEAR);
        try writer.print("{d} year{s} ago", .{ years, if (years == 1) "" else "s" });
    }

    try writer.writeAll("</span>");
}

pub fn formatBytes(writer: anytype, bytes: u64) !void {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var size = @as(f64, @floatFromInt(bytes));
    var unit_idx: usize = 0;

    while (size >= 1024 and unit_idx < units.len - 1) {
        size /= 1024;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        try writer.print("{d} {s}", .{ bytes, units[unit_idx] });
    } else {
        try writer.print("{d:.2} {s}", .{ size, units[unit_idx] });
    }
}

pub fn truncateString(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) {
        return text;
    }
    return text[0..max_len];
}

pub fn writeCommitLink(ctx: *gitweb.Context, writer: anytype, oid: []const u8, text: ?[]const u8) !void {
    const display_text = text orelse oid[0..7];
    if (ctx.repo) |repo| {
        try writer.print("<a href='?r={s}&cmd=commit&id={s}", .{ repo.name, oid });
    } else {
        try writer.print("<a href='?cmd=commit&id={s}", .{oid});
    }

    // Include branch parameter if present
    if (ctx.query.get("h")) |branch| {
        try writer.print("&h={s}", .{branch});
    }

    try writer.writeAll("'>");
    try html.htmlEscape(writer, display_text);
    try writer.writeAll("</a>");
}

pub fn writeTreeLink(ctx: *gitweb.Context, writer: anytype, oid: []const u8, path: ?[]const u8, text: ?[]const u8) !void {
    const display_text = text orelse "tree";
    try writer.writeAll("<a href='?");
    if (ctx.repo) |repo| {
        try writer.print("r={s}&", .{repo.name});
    }
    try writer.print("cmd=tree&id={s}", .{oid});
    if (ctx.query.get("h")) |branch| {
        try writer.print("&h={s}", .{branch});
    }
    if (path) |p| {
        try writer.writeAll("&path=");
        try html.urlEncode(writer, p);
    }
    try writer.writeAll("'>");
    try html.htmlEscape(writer, display_text);
    try writer.writeAll("</a>");
}

pub fn writeDiffLink(ctx: *gitweb.Context, writer: anytype, old_oid: []const u8, new_oid: []const u8, path: ?[]const u8, text: ?[]const u8) !void {
    const display_text = text orelse "diff";
    try writer.writeAll("<a href='?");
    if (ctx.repo) |repo| {
        try writer.print("r={s}&", .{repo.name});
    }
    try writer.print("cmd=diff&id={s}&id2={s}", .{ new_oid, old_oid });
    if (ctx.query.get("h")) |branch| {
        try writer.print("&h={s}", .{branch});
    }
    if (path) |p| {
        try writer.writeAll("&path=");
        try html.urlEncode(writer, p);
    }
    try writer.writeAll("'>");
    try html.htmlEscape(writer, display_text);
    try writer.writeAll("</a>");
}

const git = @import("../git.zig");
const parsing = @import("../parsing.zig");

// Repository opening helper that handles error display consistently
pub fn openRepositoryWithError(ctx: *gitweb.Context, writer: anytype) !?git.Repository {
    const repo = ctx.repo orelse return error.NoRepository;
    const git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("<p>Unable to open repository.</p>\n");
        try writer.writeAll("</div>\n");
        return null;
    };
    return git_repo;
}

// Resolve a reference by trying multiple prefixes
pub fn resolveReference(ctx: *gitweb.Context, repo: *git.Repository, ref_name: []const u8) !git.Reference {
    // Try direct reference
    if (repo.getReference(ref_name)) |ref| {
        return ref;
    } else |_| {}

    // Try with refs/heads/ prefix
    const full_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_name}, 0);
    defer ctx.allocator.free(full_ref);
    if (repo.getReference(full_ref)) |ref| {
        return ref;
    } else |_| {}

    // Try with refs/tags/ prefix
    const tag_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/tags/{s}", .{ref_name}, 0);
    defer ctx.allocator.free(tag_ref);
    return repo.getReference(tag_ref);
}

// Resolve a reference or fall back to HEAD
pub fn resolveReferenceOrHead(ctx: *gitweb.Context, repo: *git.Repository, ref_name: []const u8) !git.Reference {
    return resolveReference(ctx, repo, ref_name) catch repo.getHead();
}

// Build a refs map from branches and tags for commit decoration
pub fn collectRefsMap(ctx: *gitweb.Context, repo: *git.Repository) !std.StringHashMap(std.ArrayList([]const u8)) {
    var refs_map = std.StringHashMap(std.ArrayList([]const u8)).init(ctx.allocator);
    errdefer {
        var iter = refs_map.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.items) |item| {
                ctx.allocator.free(item);
            }
            entry.value_ptr.deinit(ctx.allocator);
            ctx.allocator.free(entry.key_ptr.*);
        }
        refs_map.deinit();
    }

    // Collect branches
    const branches = try repo.getBranches(ctx.allocator);
    defer ctx.allocator.free(branches);

    for (branches) |branch| {
        if (!branch.is_remote) {
            defer @constCast(&branch.ref).free();

            const oid = @constCast(&branch.ref).target() orelse continue;
            var oid_str: [40]u8 = undefined;
            _ = git.c.git_oid_fmt(&oid_str, oid);

            const result = try refs_map.getOrPut(&oid_str);
            if (!result.found_existing) {
                const key = try ctx.allocator.dupe(u8, &oid_str);
                result.key_ptr.* = key;
                result.value_ptr.* = std.ArrayList([]const u8).empty;
            }

            const branch_name = try ctx.allocator.dupe(u8, branch.name);
            try result.value_ptr.append(ctx.allocator, branch_name);
        }
    }

    // Collect tags
    const tags = try repo.getTags(ctx.allocator);
    defer {
        for (tags) |tag| {
            ctx.allocator.free(tag.name);
            @constCast(&tag.ref).free();
        }
        ctx.allocator.free(tags);
    }

    for (tags) |tag| {
        const oid = @constCast(&tag.ref).target() orelse continue;
        var oid_str: [40]u8 = undefined;
        _ = git.c.git_oid_fmt(&oid_str, oid);

        const result = try refs_map.getOrPut(&oid_str);
        if (!result.found_existing) {
            const key = try ctx.allocator.dupe(u8, &oid_str);
            result.key_ptr.* = key;
            result.value_ptr.* = std.ArrayList([]const u8).empty;
        }

        const tag_name = try ctx.allocator.dupe(u8, tag.name);
        try result.value_ptr.append(ctx.allocator, tag_name);
    }

    return refs_map;
}

// URL builder with common parameters
pub const UrlParams = struct {
    cmd: []const u8,
    id: ?[]const u8 = null,
    h: ?[]const u8 = null,
    path: ?[]const u8 = null,
    ofs: ?usize = null,
    id2: ?[]const u8 = null,
    fmt: ?[]const u8 = null,
};

pub fn buildUrl(writer: anytype, ctx: *gitweb.Context, params: UrlParams) !void {
    try writer.writeAll("?");

    // Always include repo if present
    if (ctx.repo) |repo| {
        try writer.print("r={s}&", .{repo.name});
    }

    // Command is required
    try writer.print("cmd={s}", .{params.cmd});

    // Optional parameters
    if (params.id) |id| {
        try writer.print("&id={s}", .{id});
    }

    if (params.h) |h| {
        try writer.print("&h={s}", .{h});
    } else if (ctx.query.get("h")) |h| {
        // Preserve current branch if not overridden
        try writer.print("&h={s}", .{h});
    }

    if (params.path) |path| {
        try writer.writeAll("&path=");
        try html.urlEncodePath(writer, path);
    }

    if (params.ofs) |ofs| {
        try writer.print("&ofs={d}", .{ofs});
    }

    if (params.id2) |id2| {
        try writer.print("&id2={s}", .{id2});
    }

    if (params.fmt) |fmt| {
        try writer.print("&fmt={s}", .{fmt});
    }
}

// Write a standard commit table row
pub fn writeCommitRow(ctx: *gitweb.Context, writer: anytype, commit: *git.Commit, refs: ?[]const u8, show_graph: bool) !void {
    try writer.writeAll("<tr>\n");

    // Graph column if requested
    if (show_graph) {
        try writer.writeAll("<td class='graph'></td>\n");
    }

    // Age column
    try writer.writeAll("<td class='age'>");
    try formatAge(writer, commit.time);
    try writer.writeAll("</td>\n");

    // Author column
    try writer.writeAll("<td class='author'>");
    const author = commit.getAuthor();
    try html.htmlEscape(writer, truncateString(author.name, 20));
    try writer.writeAll("</td>\n");

    // Message column with refs
    try writer.writeAll("<td class='message'>");

    var oid_str: [40]u8 = undefined;
    _ = git.c.git_oid_fmt(&oid_str, &commit.oid);

    try writeCommitLink(ctx, writer, &oid_str, null);
    try writer.writeAll(" ");

    const parsed = parsing.parseCommitMessage(commit.getMessage());
    try html.htmlEscape(writer, parsed.subject);

    if (refs) |ref_list| {
        try writer.print(" <span class='refs'>{s}</span>", .{ref_list});
    }

    try writer.writeAll("</td>\n");

    try writer.writeAll("</tr>\n");
}

// Shared branch info structure
pub const BranchItemInfo = struct {
    name: []const u8,
    is_head: bool,
    oid_str: [40]u8,
    author_name: []const u8,
    message: []const u8,
    timestamp: i64,
};

// Render a branch item in the unified card style
pub fn writeBranchItem(ctx: *gitweb.Context, writer: anytype, info: BranchItemInfo, css_prefix: []const u8) !void {
    try writer.print("<div class='{s}-item", .{css_prefix});
    if (info.is_head) {
        try writer.print(" {s}-current", .{css_prefix});
    }
    try writer.writeAll("'>\n");

    // First line: branch name only
    try writer.print("<div class='{s}-name'>\n", .{css_prefix});
    if (ctx.repo) |r| {
        try writer.print("<a href='?r={s}&cmd=log&h={s}'>{s}</a>", .{ r.name, info.name, info.name });
    } else {
        try writer.print("<a href='?cmd=log&h={s}'>{s}</a>", .{ info.name, info.name });
    }
    if (info.is_head) {
        try writer.print(" <span class='{s}-head'>HEAD</span>", .{css_prefix});
    }
    try writer.writeAll("</div>\n");

    // Second line: commit message (full first line, no truncation)
    try writer.print("<div class='{s}-message'>\n", .{css_prefix});
    // Parse the message to get just the first line
    const parsed_msg = parsing.parseCommitMessage(info.message);
    try html.htmlEscape(writer, parsed_msg.subject);
    try writer.writeAll("</div>\n");

    // Third line: metadata
    try writer.print("<div class='{s}-meta'>\n", .{css_prefix});

    // Commit hash
    try writer.print("<span class='{s}-hash'>", .{css_prefix});
    try writeCommitLink(ctx, writer, &info.oid_str, info.oid_str[0..7]);
    try writer.writeAll("</span>");

    // Author
    try writer.print("<span class='{s}-author'>", .{css_prefix});
    try html.htmlEscape(writer, parsing.truncateString(info.author_name, 20));
    try writer.writeAll("</span>");

    // Age
    try writer.print("<span class='{s}-age' data-timestamp='{d}'>", .{ css_prefix, info.timestamp });
    try formatAge(writer, info.timestamp);
    try writer.writeAll("</span>");

    try writer.writeAll("</div>\n"); // meta
    try writer.writeAll("</div>\n"); // item
}

// Shared tag info structure
pub const TagItemInfo = struct {
    name: []const u8,
    oid_str: [40]u8,
    author_name: []const u8,
    message: []const u8,
    timestamp: i64,
};

// Render a tag item in the unified card style
pub fn writeTagItem(ctx: *gitweb.Context, writer: anytype, info: TagItemInfo, css_prefix: []const u8) !void {
    try writer.print("<div class='{s}-item'>\n", .{css_prefix});

    // First line: tag name only
    try writer.print("<div class='{s}-name'>\n", .{css_prefix});
    if (ctx.repo) |r| {
        try writer.print("<a href='?r={s}&cmd=tag&h={s}'>{s}</a>", .{ r.name, info.name, info.name });
    } else {
        try writer.print("<a href='?cmd=tag&h={s}'>{s}</a>", .{ info.name, info.name });
    }
    try writer.writeAll("</div>\n");

    // Second line: commit message (full first line, no truncation)
    try writer.print("<div class='{s}-message'>\n", .{css_prefix});
    // Parse the message to get just the first line
    const parsed_msg = parsing.parseCommitMessage(info.message);
    try html.htmlEscape(writer, parsed_msg.subject);
    try writer.writeAll("</div>\n");

    // Metadata
    try writer.print("<div class='{s}-meta'>\n", .{css_prefix});

    // Hash
    try writer.print("<span class='{s}-hash'>", .{css_prefix});
    try writeCommitLink(ctx, writer, &info.oid_str, info.oid_str[0..7]);
    try writer.writeAll("</span>");

    // Author
    try writer.print("<span class='{s}-author'>", .{css_prefix});
    try html.htmlEscape(writer, parsing.truncateString(info.author_name, 20));
    try writer.writeAll("</span>");

    // Age
    try writer.print("<span class='{s}-age' data-timestamp='{d}'>", .{ css_prefix, info.timestamp });
    try formatAge(writer, info.timestamp);
    try writer.writeAll("</span>");

    // Download links
    try writer.print("<span class='{s}-download'>", .{css_prefix});
    if (ctx.repo) |r| {
        try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> | ", .{ r.name, info.name });
        try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{ r.name, info.name });
    } else {
        try writer.print("<a href='?cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> | ", .{info.name});
        try writer.print("<a href='?cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{info.name});
    }
    try writer.writeAll("</span>");

    try writer.writeAll("</div>\n"); // meta
    try writer.writeAll("</div>\n"); // item
}

// Shared commit info structure
pub const CommitItemInfo = struct {
    oid_str: [40]u8,
    message: []const u8,
    author_name: []const u8,
    timestamp: i64,
    refs: ?[]const RefInfo = null,

    pub const RefInfo = struct {
        name: []const u8,
        ref_type: enum { branch, tag },
    };
};

// Render a commit item in the unified card style
pub fn writeCommitItem(ctx: *gitweb.Context, writer: anytype, info: CommitItemInfo, css_prefix: []const u8) !void {
    try writer.print("<div class='{s}-item'>\n", .{css_prefix});

    // First line: commit message with inline refs
    try writer.print("<div class='{s}-message'>\n", .{css_prefix});
    try html.htmlEscape(writer, info.message);

    // Show refs (branches and tags) inline at the end if present
    if (info.refs) |refs| {
        try writer.writeAll(" ");
        for (refs) |ref_info| {
            switch (ref_info.ref_type) {
                .branch => {
                    try writer.writeAll("<span class='ref-branch'>");
                    try html.htmlEscape(writer, ref_info.name);
                    try writer.writeAll("</span> ");
                },
                .tag => {
                    try writer.writeAll("<span class='ref-tag'>");
                    try html.htmlEscape(writer, ref_info.name);
                    try writer.writeAll("</span> ");
                },
            }
        }
    }

    try writer.writeAll("</div>\n");

    // Second line: metadata
    try writer.print("<div class='{s}-meta'>\n", .{css_prefix});

    // Commit hash
    try writer.print("<span class='{s}-hash'>", .{css_prefix});
    try writeCommitLink(ctx, writer, &info.oid_str, info.oid_str[0..7]);
    try writer.writeAll("</span>");

    // Author
    try writer.print("<span class='{s}-author'>", .{css_prefix});
    try html.htmlEscape(writer, parsing.truncateString(info.author_name, 20));
    try writer.writeAll("</span>");

    // Age
    try writer.print("<span class='{s}-age' data-timestamp='{d}'>", .{ css_prefix, info.timestamp });
    try formatAge(writer, info.timestamp);
    try writer.writeAll("</span>");

    try writer.writeAll("</div>\n"); // meta
    try writer.writeAll("</div>\n"); // item
}

pub fn writeBreadcrumb(ctx: *gitweb.Context, writer: anytype, path: []const u8) !void {
    try writer.writeAll("<h2 class='path'>");

    // Add root link
    try writer.writeAll("<a href='?");
    if (ctx.repo) |repo| {
        try writer.print("r={s}&", .{repo.name});
    }
    try writer.writeAll("cmd=tree");
    if (ctx.query.get("id")) |id| {
        try writer.print("&id={s}", .{id});
    } else if (ctx.query.get("h")) |branch| {
        try writer.print("&h={s}", .{branch});
    }
    try writer.writeAll("'>root</a>");

    var iter = std.mem.tokenizeAny(u8, path, "/");
    var accumulated = std.ArrayList(u8){
        .items = &.{},
        .capacity = 0,
    };
    defer accumulated.deinit(ctx.allocator);

    while (iter.next()) |segment| {
        try writer.writeAll(" / ");

        if (accumulated.items.len > 0) {
            try accumulated.append(ctx.allocator, '/');
        }
        try accumulated.appendSlice(ctx.allocator, segment);

        if (iter.peek() != null) {
            try writer.writeAll("<a href='?");
            if (ctx.repo) |repo| {
                try writer.print("r={s}&", .{repo.name});
            }
            try writer.writeAll("cmd=tree");
            if (ctx.query.get("id")) |id| {
                try writer.print("&id={s}", .{id});
            } else if (ctx.query.get("h")) |branch| {
                try writer.print("&h={s}", .{branch});
            }
            try writer.writeAll("&path=");
            try html.urlEncodePath(writer, accumulated.items);
            try writer.writeAll("'>");
            try html.htmlEscape(writer, segment);
            try writer.writeAll("</a>");
        } else {
            try html.htmlEscape(writer, segment);
        }
    }

    try writer.writeAll("</h2>\n");
}

// Thread-local buffer for reference name construction
threadlocal var ref_buf: [256]u8 = undefined;

pub fn tryResolveRef(repo: *git.Repository, ref_name: []const u8) ?git.Reference {
    // Try direct reference first
    if (repo.getReference(ref_name)) |ref| {
        return ref;
    } else |_| {}

    // Try with refs/heads/ prefix
    const branch_ref = std.fmt.bufPrint(&ref_buf, "refs/heads/{s}", .{ref_name}) catch return null;
    if (repo.getReference(branch_ref)) |ref| {
        return ref;
    } else |_| {}

    // Try with refs/tags/ prefix
    const tag_ref = std.fmt.bufPrint(&ref_buf, "refs/tags/{s}", .{ref_name}) catch return null;
    if (repo.getReference(tag_ref)) |ref| {
        return ref;
    } else |_| {}

    return null;
}

pub fn formatBranchRef(buf: []u8, ref_name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "refs/heads/{s}", .{ref_name});
}

pub fn formatTagRef(buf: []u8, ref_name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "refs/tags/{s}", .{ref_name});
}

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
    
    // First line: branch name and message
    try writer.print("<div class='{s}-top'>\n", .{css_prefix});
    
    // Name
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
    
    // Message
    try writer.print("<div class='{s}-message'>\n", .{css_prefix});
    const truncated = parsing.truncateString(info.message, 60);
    try html.htmlEscape(writer, truncated);
    try writer.writeAll("</div>\n");
    
    try writer.writeAll("</div>\n"); // top
    
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
    
    // First line: tag name and download links
    try writer.print("<div class='{s}-top'>\n", .{css_prefix});
    
    // Name
    try writer.print("<div class='{s}-name'>\n", .{css_prefix});
    if (ctx.repo) |r| {
        try writer.print("<a href='?r={s}&cmd=tag&h={s}'>{s}</a>", .{ r.name, info.name, info.name });
    } else {
        try writer.print("<a href='?cmd=tag&h={s}'>{s}</a>", .{ info.name, info.name });
    }
    try writer.writeAll("</div>\n");
    
    // Download links
    try writer.print("<div class='{s}-download'>\n", .{css_prefix});
    if (ctx.repo) |r| {
        try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> | ", .{ r.name, info.name });
        try writer.print("<a href='?r={s}&cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{ r.name, info.name });
    } else {
        try writer.print("<a href='?cmd=snapshot&h={s}&fmt=tar.gz'>tar.gz</a> | ", .{info.name});
        try writer.print("<a href='?cmd=snapshot&h={s}&fmt=zip'>zip</a>", .{info.name});
    }
    try writer.writeAll("</div>\n");
    
    try writer.writeAll("</div>\n"); // top
    
    // Message
    try writer.print("<div class='{s}-message'>\n", .{css_prefix});
    const truncated = parsing.truncateString(info.message, 60);
    try html.htmlEscape(writer, truncated);
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
    try writer.writeAll("<div class='path'>");
    try writer.writeAll("path: ");

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

    try writer.writeAll("</div>\n");
}

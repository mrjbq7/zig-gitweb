const std = @import("std");
const gitweb = @import("../gitweb.zig");
const git = @import("../git.zig");

const c = @cImport({
    @cInclude("git2.h");
    @cInclude("unistd.h");
});

pub fn snapshot(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    const ref_str = ctx.query.get("h") orelse ctx.query.get("id") orelse "HEAD";
    const fmt = ctx.query.get("fmt") orelse ctx.query.get("format") orelse "tar.gz";
    const path_filter = ctx.query.get("path");

    // Determine format and set content type
    const format = if (std.mem.eql(u8, fmt, "tar.gz") or std.mem.eql(u8, fmt, "tgz"))
        Format.tar_gz
    else if (std.mem.eql(u8, fmt, "tar.bz2") or std.mem.eql(u8, fmt, "tbz2"))
        Format.tar_bz2
    else if (std.mem.eql(u8, fmt, "tar.xz") or std.mem.eql(u8, fmt, "txz"))
        Format.tar_xz
    else if (std.mem.eql(u8, fmt, "tar"))
        Format.tar
    else if (std.mem.eql(u8, fmt, "zip"))
        Format.zip
    else
        return error.UnsupportedFormat;

    // Open repository
    var git_repo = git.Repository.open(repo.path) catch return error.RepoOpenFailed;
    defer git_repo.close();

    // Resolve reference
    var oid = git.stringToOid(ref_str) catch blk: {
        // Try as reference name
        var ref = git_repo.getReference(ref_str) catch {
            return error.InvalidReference;
        };
        defer ref.free();
        const target = ref.target() orelse return error.InvalidReference;
        break :blk target.*;
    };

    // Get commit
    var commit = try git_repo.lookupCommit(&oid);
    defer commit.free();

    // Get tree
    var tree = try commit.tree();
    defer tree.free();

    // Generate filename prefix (repo-name-shortref)
    const short_ref = if (ref_str.len > 7) ref_str[0..7] else ref_str;
    const prefix = try std.fmt.allocPrint(ctx.allocator, "{s}-{s}", .{ repo.name, short_ref });
    defer ctx.allocator.free(prefix);

    // Set response headers
    switch (format) {
        .tar => {
            ctx.page.mimetype = "application/x-tar";
            ctx.page.filename = try std.fmt.allocPrint(ctx.allocator, "{s}.tar", .{prefix});
        },
        .tar_gz => {
            ctx.page.mimetype = "application/x-gzip";
            ctx.page.filename = try std.fmt.allocPrint(ctx.allocator, "{s}.tar.gz", .{prefix});
        },
        .tar_bz2 => {
            ctx.page.mimetype = "application/x-bzip2";
            ctx.page.filename = try std.fmt.allocPrint(ctx.allocator, "{s}.tar.bz2", .{prefix});
        },
        .tar_xz => {
            ctx.page.mimetype = "application/x-xz";
            ctx.page.filename = try std.fmt.allocPrint(ctx.allocator, "{s}.tar.xz", .{prefix});
        },
        .zip => {
            ctx.page.mimetype = "application/zip";
            ctx.page.filename = try std.fmt.allocPrint(ctx.allocator, "{s}.zip", .{prefix});
        },
    }

    // Generate archive based on format
    switch (format) {
        .tar, .tar_gz, .tar_bz2, .tar_xz => try generateTarArchive(ctx, &git_repo, repo.path, &tree, prefix, path_filter, format, writer),
        .zip => try generateZipArchive(ctx, &git_repo, &tree, prefix, path_filter, writer),
    }
}

const Format = enum {
    tar,
    tar_gz,
    tar_bz2,
    tar_xz,
    zip,
};

fn generateTarArchive(
    ctx: *gitweb.Context,
    repo: *git.Repository,
    repo_path: []const u8,
    tree: *git.Tree,
    prefix: []const u8,
    path_filter: ?[]const u8,
    format: Format,
    writer: anytype,
) !void {
    _ = ctx;
    _ = repo;
    _ = tree;
    _ = prefix;
    _ = path_filter;

    // Create pipes for tar command
    var pipe_fds: [2]c_int = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.PipeCreationFailed;

    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    // Fork process for tar generation
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(read_fd);
        _ = c.close(write_fd);
        return error.ForkFailed;
    }

    if (pid == 0) {
        // Child process: run tar command
        _ = c.close(read_fd);
        _ = c.dup2(write_fd, 1); // Redirect stdout to pipe
        _ = c.close(write_fd);

        // Execute git archive command
        const git_cmd = "git";
        const archive_args = switch (format) {
            .tar => [_:null]?[*:0]const u8{ git_cmd, "archive", "--format=tar", "HEAD" },
            .tar_gz => [_:null]?[*:0]const u8{ git_cmd, "archive", "--format=tar.gz", "HEAD" },
            .tar_bz2 => [_:null]?[*:0]const u8{ git_cmd, "archive", "--format=tar", "HEAD" },
            .tar_xz => [_:null]?[*:0]const u8{ git_cmd, "archive", "--format=tar", "HEAD" },
            else => unreachable,
        };

        const c_path = try std.heap.c_allocator.dupeZ(u8, repo_path);
        defer std.heap.c_allocator.free(c_path);
        _ = c.chdir(c_path);
        _ = c.execvp(git_cmd, @ptrCast(&archive_args));
        std.process.exit(1);
    }

    // Parent process: read from pipe and write to output
    _ = c.close(write_fd);

    var buffer: [8192]u8 = undefined;
    while (true) {
        const bytes_read = c.read(read_fd, &buffer, buffer.len);
        if (bytes_read <= 0) break;

        try writer.writeAll(buffer[0..@intCast(bytes_read)]);
    }

    _ = c.close(read_fd);

    // Wait for child process
    var status: c_int = undefined;
    _ = c.waitpid(pid, &status, 0);
}

fn generateZipArchive(
    ctx: *gitweb.Context,
    repo: *git.Repository,
    tree: *git.Tree,
    prefix: []const u8,
    path_filter: ?[]const u8,
    writer: anytype,
) !void {
    _ = ctx;
    _ = repo;
    _ = tree;
    _ = prefix;
    _ = path_filter;

    // For ZIP archives, we would need to implement ZIP format generation
    // or use an external command. For now, return a placeholder.
    try writer.writeAll("ZIP archive generation not yet implemented\n");
}

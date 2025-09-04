const std = @import("std");
const gitweb = @import("../gitweb.zig");
const git = @import("../git.zig");

const c = @cImport({
    @cInclude("git2.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
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
        // Try with refs/tags/ prefix first (most common for snapshots)
        const tag_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/tags/{s}", .{ref_str}, 0);
        defer ctx.allocator.free(tag_ref);

        var ref = git_repo.getReference(tag_ref) catch {
            // Try with refs/heads/ prefix
            const branch_ref = try std.fmt.allocPrintSentinel(ctx.allocator, "refs/heads/{s}", .{ref_str}, 0);
            defer ctx.allocator.free(branch_ref);

            var ref2 = git_repo.getReference(branch_ref) catch {
                // Try as bare reference name (might be fully qualified already)
                var ref3 = git_repo.getReference(ref_str) catch {
                    return error.InvalidReference;
                };
                defer ref3.free();
                const target = ref3.target() orelse return error.InvalidReference;
                break :blk target.*;
            };
            defer ref2.free();
            const target = ref2.target() orelse return error.InvalidReference;
            break :blk target.*;
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
        .tar, .tar_gz, .tar_bz2, .tar_xz => try generateTarArchive(ctx, &git_repo, repo.path, &tree, prefix, ref_str, path_filter, format, writer),
        .zip => try generateZipArchive(ctx, &git_repo, repo.path, &tree, prefix, ref_str, path_filter, writer),
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
    ref_str: []const u8,
    path_filter: ?[]const u8,
    format: Format,
    writer: anytype,
) !void {
    _ = repo;
    _ = tree;
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

        // Build the prefix argument with trailing slash
        const prefix_arg = try std.fmt.allocPrintSentinel(ctx.allocator, "{s}/", .{prefix}, 0);
        defer ctx.allocator.free(prefix_arg);

        // Build the ref argument
        const ref_arg = try std.heap.c_allocator.dupeZ(u8, ref_str);
        defer std.heap.c_allocator.free(ref_arg);

        // Change to repository directory
        const c_path = try std.heap.c_allocator.dupeZ(u8, repo_path);
        defer std.heap.c_allocator.free(c_path);
        _ = c.chdir(c_path);

        // Execute git archive command, potentially with compression
        const git_cmd = "git";

        switch (format) {
            .tar => {
                const archive_args = [_:null]?[*:0]const u8{ git_cmd, "archive", "--format=tar", "--prefix", prefix_arg, ref_arg, null };
                _ = c.execvp(git_cmd, @ptrCast(&archive_args));
            },
            .tar_gz => {
                const archive_args = [_:null]?[*:0]const u8{ git_cmd, "archive", "--format=tar.gz", "--prefix", prefix_arg, ref_arg, null };
                _ = c.execvp(git_cmd, @ptrCast(&archive_args));
            },
            .tar_bz2 => {
                // git doesn't support tar.bz2 directly, so we pipe through bzip2
                const sh_cmd = "/bin/sh";
                const cmd_str = try std.fmt.allocPrintSentinel(ctx.allocator, "git archive --format=tar --prefix={s}/ {s} | bzip2", .{ prefix, ref_str }, 0);
                defer ctx.allocator.free(cmd_str);
                const sh_args = [_:null]?[*:0]const u8{ sh_cmd, "-c", cmd_str, null };
                _ = c.execvp(sh_cmd, @ptrCast(&sh_args));
            },
            .tar_xz => {
                // git doesn't support tar.xz directly, so we pipe through xz
                const sh_cmd = "/bin/sh";
                const cmd_str = try std.fmt.allocPrintSentinel(ctx.allocator, "git archive --format=tar --prefix={s}/ {s} | xz", .{ prefix, ref_str }, 0);
                defer ctx.allocator.free(cmd_str);
                const sh_args = [_:null]?[*:0]const u8{ sh_cmd, "-c", cmd_str, null };
                _ = c.execvp(sh_cmd, @ptrCast(&sh_args));
            },
            else => unreachable,
        }

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
    repo_path: []const u8,
    tree: *git.Tree,
    prefix: []const u8,
    ref_str: []const u8,
    path_filter: ?[]const u8,
    writer: anytype,
) !void {
    _ = repo;
    _ = tree;
    _ = path_filter;

    // Git has built-in ZIP support, use git archive --format=zip
    // Create pipes for git archive command
    var pipe_fds: [2]c_int = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.PipeCreationFailed;

    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    // Fork process for zip generation
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(read_fd);
        _ = c.close(write_fd);
        return error.ForkFailed;
    }

    if (pid == 0) {
        // Child process: run git archive command
        _ = c.close(read_fd);
        _ = c.dup2(write_fd, 1); // Redirect stdout to pipe
        _ = c.close(write_fd);

        // Build the prefix argument with trailing slash
        const prefix_arg = try std.fmt.allocPrintSentinel(ctx.allocator, "{s}/", .{prefix}, 0);
        defer ctx.allocator.free(prefix_arg);

        // Build the ref argument
        const ref_arg = try std.heap.c_allocator.dupeZ(u8, ref_str);
        defer std.heap.c_allocator.free(ref_arg);

        // Execute git archive command with zip format
        const git_cmd = "git";
        const archive_args = [_:null]?[*:0]const u8{ git_cmd, "archive", "--format=zip", "--prefix", prefix_arg, ref_arg, null };

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

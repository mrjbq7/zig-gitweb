const std = @import("std");
const gitweb = @import("../gitweb.zig");
const git = @import("../git.zig");

const c = @cImport({
    @cInclude("git2.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});

pub fn info(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    const service = ctx.query.get("service") orelse "git-upload-pack";

    // Only support read-only services
    if (!std.mem.eql(u8, service, "git-upload-pack")) {
        ctx.page.status = 403;
        try writer.writeAll("Forbidden\n");
        return;
    }

    // Git smart HTTP protocol info/refs
    ctx.page.mimetype = "application/x-git-upload-pack-advertisement";

    // Write service header in pkt-line format
    const service_line = try std.fmt.allocPrint(ctx.allocator, "# service={s}\n", .{service});
    defer ctx.allocator.free(service_line);

    try writePktLine(writer, service_line);
    try writer.writeAll("0000"); // Flush packet

    // Open repository
    var git_repo = git.Repository.open(repo.path) catch {
        try writer.writeAll("0000");
        return;
    };
    defer git_repo.close();

    // Get all refs
    var ref_iter: ?*c.git_reference_iterator = null;
    if (c.git_reference_iterator_new(&ref_iter, @ptrCast(git_repo.repo)) != 0) {
        try writer.writeAll("0000");
        return;
    }
    defer c.git_reference_iterator_free(ref_iter);

    var first = true;
    var ref: ?*c.git_reference = null;

    // HEAD ref
    var head: ?*c.git_reference = null;
    if (c.git_repository_head(&head, @ptrCast(git_repo.repo)) == 0) {
        defer c.git_reference_free(head);

        const head_oid = c.git_reference_target(head);
        if (head_oid != null) {
            const oid_str = try git.oidToString(@ptrCast(head_oid));

            // First ref includes capabilities
            if (first) {
                var buf: [512]u8 = undefined;
                const line = try std.fmt.bufPrint(&buf, "{s} HEAD\x00multi_ack thin-pack side-band side-band-64k ofs-delta shallow deepen-since deepen-not deepen-relative no-progress include-tag multi_ack_detailed symref=HEAD:refs/heads/master agent=zgit/0.1\n", .{oid_str});
                try writePktLine(writer, line);
                first = false;
            } else {
                var buf: [128]u8 = undefined;
                const line = try std.fmt.bufPrint(&buf, "{s} HEAD\n", .{oid_str});
                try writePktLine(writer, line);
            }
        }
    }

    // All other refs
    while (c.git_reference_next(&ref, ref_iter) == 0) {
        defer c.git_reference_free(ref);

        const ref_name = c.git_reference_name(ref);
        if (ref_name == null) continue;

        // Skip non-public refs
        const name = std.mem.span(ref_name);
        if (!std.mem.startsWith(u8, name, "refs/heads/") and
            !std.mem.startsWith(u8, name, "refs/tags/"))
        {
            continue;
        }

        const target = c.git_reference_target(ref);
        if (target == null) {
            // Symbolic ref - resolve it
            var resolved: ?*c.git_reference = null;
            if (c.git_reference_resolve(&resolved, ref) == 0) {
                defer c.git_reference_free(resolved);
                const resolved_target = c.git_reference_target(resolved);
                if (resolved_target != null) {
                    const oid_str = try git.oidToString(@ptrCast(resolved_target));

                    if (first) {
                        // Use a buffer to avoid allocation
                        var buf: [512]u8 = undefined;
                        const line = try std.fmt.bufPrint(&buf, "{s} {s}\x00multi_ack thin-pack side-band side-band-64k ofs-delta shallow deepen-since deepen-not deepen-relative no-progress include-tag multi_ack_detailed agent=zgit/0.1\n", .{ oid_str, name });
                        try writePktLine(writer, line);
                        first = false;
                    } else {
                        var buf: [256]u8 = undefined;
                        const line = try std.fmt.bufPrint(&buf, "{s} {s}\n", .{ oid_str, name });
                        try writePktLine(writer, line);
                    }
                }
            }
        } else {
            const oid_str = try git.oidToString(@ptrCast(target));

            if (first) {
                var buf: [512]u8 = undefined;
                const line = try std.fmt.bufPrint(&buf, "{s} {s}\x00multi_ack thin-pack side-band side-band-64k ofs-delta shallow deepen-since deepen-not deepen-relative no-progress include-tag multi_ack_detailed agent=zgit/0.1\n", .{ oid_str, name });
                try writePktLine(writer, line);
                first = false;
            } else {
                var buf: [256]u8 = undefined;
                const line = try std.fmt.bufPrint(&buf, "{s} {s}\n", .{ oid_str, name });
                try writePktLine(writer, line);
            }
        }

        // Also advertise peeled tags
        if (std.mem.startsWith(u8, name, "refs/tags/")) {
            var tag_obj: ?*c.git_tag = null;
            if (c.git_tag_lookup(&tag_obj, @ptrCast(git_repo.repo), target) == 0) {
                defer c.git_object_free(@ptrCast(tag_obj));

                const peeled_oid = c.git_tag_target_id(tag_obj);
                if (peeled_oid != null) {
                    const peeled_str = try git.oidToString(@ptrCast(peeled_oid));
                    var buf: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&buf, "{s} {s}^{{}}\n", .{ peeled_str, name });
                    try writePktLine(writer, line);
                }
            }
        }
    }

    try writer.writeAll("0000"); // End of refs
}

pub fn objects(ctx: *gitweb.Context, writer: anytype) !void {
    const repo = ctx.repo orelse return error.NoRepo;
    const service = ctx.query.get("service") orelse "git-upload-pack";

    // Only support read-only services
    if (!std.mem.eql(u8, service, "git-upload-pack")) {
        ctx.page.status = 403;
        try writer.writeAll("Forbidden\n");
        return;
    }

    // Git smart HTTP protocol objects - use git-upload-pack
    ctx.page.mimetype = "application/x-git-upload-pack-result";

    // For actual implementation, we need to spawn git-upload-pack process
    // and pipe the request/response through it

    const pid = c.fork();
    if (pid < 0) {
        return error.ForkFailed;
    }

    if (pid == 0) {
        // Child process: execute git-upload-pack
        const c_path = try std.heap.c_allocator.dupeZ(u8, repo.path);
        defer std.heap.c_allocator.free(c_path);
        _ = c.chdir(c_path);

        const git_cmd = "git-upload-pack";
        const args = [_:null]?[*:0]const u8{ git_cmd, "--stateless-rpc", "--advertise-refs", "." };

        _ = c.execvp(git_cmd, @ptrCast(&args));
        std.process.exit(1);
    }

    // Parent process: wait for child
    var status: c_int = undefined;
    _ = c.waitpid(pid, &status, 0);

    // For now, return empty response
    try writer.writeAll("0000");
}

fn writePktLine(writer: anytype, data: []const u8) !void {
    // Git pkt-line format: 4 hex digits for length (including the 4 bytes) + data
    const len = data.len + 4;
    if (len > 65520) return error.PktLineTooLong;

    var len_buf: [4]u8 = undefined;
    _ = try std.fmt.bufPrint(&len_buf, "{x:0>4}", .{len});

    try writer.writeAll(&len_buf);
    try writer.writeAll(data);
}

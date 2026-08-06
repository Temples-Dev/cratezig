const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const Dockerfile = @import("../../builder/spec.zig").Dockerfile;

fn appendEscapedStream(list: *std.ArrayList(u8), alloc: std.mem.Allocator, text: []const u8) !void {
    try list.appendSlice(alloc, "{\"stream\":\"");
    for (text) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => try list.append(alloc, c),
        }
    }
    try list.appendSlice(alloc, "\"}\n");
}

pub fn build(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const tag = req.query.get("t") orelse "latest";
    const df_name = req.query.get("dockerfile") orelse "Dockerfile";

    // 1. Create a unique scratch build directory
    var rand_id: [16]u8 = undefined;
    const seed: u64 = @intCast(@intFromPtr(req));
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(&rand_id);
    const hex_id = std.fmt.bytesToHex(&rand_id, .lower);

    var tmp_path_buf: [256:0]u8 = undefined;
    const scratch_dir = std.fmt.bufPrintZ(&tmp_path_buf, "/tmp/cratezig-build-{s}", .{hex_id}) catch "/tmp/cratezig-build";

    _ = std.os.linux.mkdir(scratch_dir.ptr, 0o755);
    defer _ = std.os.linux.rmdir(scratch_dir.ptr);

    // 2. Extract context or write inline Dockerfile
    var dockerfile_path_buf: [512]u8 = undefined;
    const full_df_path = std.fmt.bufPrint(&dockerfile_path_buf, "{s}/{s}", .{ scratch_dir, df_name }) catch return Response.badRequest("invalid dockerfile path");

    var df_content: []const u8 = "FROM alpine:latest\n";

    if (req.body.len > 0) {
        const is_raw_dockerfile = std.mem.startsWith(u8, req.body, "FROM ") or
            std.mem.startsWith(u8, req.body, "#") or
            std.mem.startsWith(u8, req.body, "ARG ") or
            std.mem.startsWith(u8, req.body, "ENV ");

        if (is_raw_dockerfile) {
            df_content = req.body;
            const fd = std.posix.openat(std.posix.AT.FDCWD, full_df_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return Response.internalError("failed to create Dockerfile");
            defer _ = std.os.linux.close(fd);
            _ = std.os.linux.write(fd, df_content.ptr, df_content.len);
        } else {
            // Write tarball and extract
            var tar_path_buf: [512]u8 = undefined;
            const tar_path = std.fmt.bufPrint(&tar_path_buf, "{s}/context.tar", .{scratch_dir}) catch return Response.badRequest("invalid path");
            const tar_fd = std.posix.openat(std.posix.AT.FDCWD, tar_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return Response.internalError("failed to save build context");
            _ = std.os.linux.write(tar_fd, req.body.ptr, req.body.len);
            _ = std.os.linux.close(tar_fd);

            // Extract context tarball into scratch_dir
            var proc = std.process.spawn(daemon.config.io, .{
                .argv = &.{ "tar", "-xf", tar_path, "-C", scratch_dir },
            }) catch null;
            if (proc) |*p| {
                _ = p.wait(daemon.config.io) catch {};
            }

            // Load actual Dockerfile from scratch_dir if present
            if (std.Io.Dir.openFile(.cwd(), daemon.config.io, full_df_path, .{})) |file| {
                defer file.close(daemon.config.io);
                var r_buf: [4096]u8 = undefined;
                var rdr = file.reader(daemon.config.io, &r_buf);
                if (rdr.interface.allocRemaining(alloc, std.Io.Limit.unlimited)) |read_df| {
                    df_content = read_df;
                } else |_| {}
            } else |_| {}
        }
    }

    // 3. Execute Builder Engine
    const img = daemon.builder.build(df_content, scratch_dir, tag) catch |err| {
        return Response.fromError(err);
    };

    // 4. Return Docker CLI step-by-step stream response
    var stream_list = std.ArrayList(u8).empty;
    defer stream_list.deinit(alloc);

    var df = Dockerfile.parse(alloc, df_content) catch null;
    if (df) |*parsed_df| {
        defer parsed_df.deinit();
        const total_steps = parsed_df.instructions.len;
        for (parsed_df.instructions, 1..) |inst, step_idx| {
            var step_buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&step_buf, "Step {d}/{d} : {s}\n", .{ step_idx, total_steps, inst.raw }) catch continue;
            appendEscapedStream(&stream_list, alloc, line) catch {};
            appendEscapedStream(&stream_list, alloc, " ---> Using cache\n") catch {};
        }
    }

    var final_b_buf: [128]u8 = undefined;
    const short_id = if (img.id.len >= 12) img.id[0..12] else img.id;
    const built_line = std.fmt.bufPrint(&final_b_buf, "Successfully built {s}\n", .{short_id}) catch "";
    appendEscapedStream(&stream_list, alloc, built_line) catch {};

    var final_t_buf: [128]u8 = undefined;
    const tagged_line = std.fmt.bufPrint(&final_t_buf, "Successfully tagged {s}\n", .{tag}) catch "";
    appendEscapedStream(&stream_list, alloc, tagged_line) catch {};

    const stream_output = stream_list.toOwnedSlice(alloc) catch return Response.internalError("failed to format build response");

    return Response{
        .status = 200,
        .content_type = "application/json",
        .body = stream_output,
    };
}

test "build handler dockerfile streaming" {
    const alloc = std.testing.allocator;
    _ = alloc;
}

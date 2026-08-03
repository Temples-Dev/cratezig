const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const Container = @import("../container/container.zig").Container;
const ExecProcess = @import("../container/container.zig").ExecProcess;
const runc = @import("../runtime/runc.zig");

pub fn containerExecCreate(daemon: *Daemon, container_name: []const u8, cmd: []const []const u8, privileged: bool, tty: bool, allocator: std.mem.Allocator) ![]const u8 {
    const ctr = daemon.containers.get(container_name) orelse return error.ContainerNotFound;

    ctr.lock();
    const is_running = ctr.state.running;
    ctr.unlock();

    if (!is_running) {
        return error.ContainerNotRunning;
    }

    var bytes: [16]u8 = undefined;
    try daemon.config.io.randomSecure(&bytes);
    
    var hex_buf: [32]u8 = undefined;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    @memcpy(&hex_buf, &hex);
    
    const exec_id = try std.fmt.allocPrint(allocator, "exec-{s}", .{hex_buf});
    errdefer allocator.free(exec_id);

    var cmd_dup = try allocator.alloc([]const u8, cmd.len);
    errdefer allocator.free(cmd_dup);
    for (cmd, 0..) |arg, i| {
        cmd_dup[i] = try allocator.dupe(u8, arg);
    }

    const exec_proc = try allocator.create(ExecProcess);
    exec_proc.* = .{
        .id = exec_id,
        .running = false,
        .exit_code = 0,
        .pid = 0,
        .tty = tty,
        .container_id = try allocator.dupe(u8, ctr.id[0..]),
        .cmd = cmd_dup,
        .privileged = privileged,
    };

    ctr.lock();
    try ctr.exec_commands.put(exec_id, exec_proc);
    ctr.unlock();

    const now = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();
    daemon.events.publish(.{
        .event_type = .container,
        .action = "exec_create",
        .actor_id = ctr.id[0..],
        .actor_attrs = std.StringHashMap([]const u8).init(daemon.allocator),
        .time_nano = now,
    });

    return exec_id;
}

pub fn containerExecStart(daemon: *Daemon, exec_id: []const u8) !void {
    var found_ctr: ?*Container = null;
    var found_ep: ?*ExecProcess = null;

    const list = try daemon.containers.list(daemon.allocator);
    defer daemon.allocator.free(list);

    for (list) |ctr| {
        ctr.lock();
        if (ctr.exec_commands.get(exec_id)) |ep| {
            found_ctr = ctr;
            found_ep = ep;
        }
        ctr.unlock();
        if (found_ctr != null) break;
    }

    const ctr = found_ctr orelse return error.ExecNotFound;
    const ep = found_ep.?;

    ctr.lock();
    const container_id = ctr.id[0..];
    const is_running = ctr.state.running;
    ctr.unlock();

    if (!is_running) return error.ContainerNotRunning;

    var spec_path_buf: [512]u8 = undefined;
    const spec_path = try std.fmt.bufPrint(&spec_path_buf, "/run/runc/{s}/exec-{s}.json", .{ container_id, exec_id });

    var json_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&json_buf);

    try writer.writeAll("{\"terminal\":");
    try writer.print("{},", .{ep.tty});
    try writer.writeAll("\"user\":{\"uid\":0,\"gid\":0},");
    try writer.writeAll("\"args\":[");
    for (ep.cmd, 0..) |arg, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try writer.writeAll(arg);
        try writer.writeByte('"');
    }
    try writer.writeAll("],\"cwd\":\"/\"}");

    const spec_json = json_buf[0..(json_buf.len - writer.unusedCapacityLen())];

    const file = try std.Io.Dir.createFileAbsolute(daemon.config.io, spec_path, .{});
    defer file.close(daemon.config.io);

    try file.writePositionalAll(daemon.config.io, spec_json, 0);

    const pid = try runc.execInContainer(daemon.config.io, container_id, spec_path);

    ctr.lock();
    ep.pid = pid;
    ep.running = true;
    ctr.unlock();

    const now = std.Io.Clock.now(.awake, daemon.config.io).toNanoseconds();
    daemon.events.publish(.{
        .event_type = .container,
        .action = "exec_start",
        .actor_id = container_id,
        .actor_attrs = std.StringHashMap([]const u8).init(daemon.allocator),
        .time_nano = now,
    });
}

pub fn containerExecInspect(daemon: *Daemon, exec_id: []const u8) !*ExecProcess {
    const list = try daemon.containers.list(daemon.allocator);
    defer daemon.allocator.free(list);

    for (list) |ctr| {
        ctr.lock();
        defer ctr.unlock();
        if (ctr.exec_commands.get(exec_id)) |ep| {
            return ep;
        }
    }
    return error.ExecNotFound;
}

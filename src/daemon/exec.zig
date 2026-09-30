const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const Container = @import("../container/container.zig").Container;
const ExecProcess = @import("../container/container.zig").ExecProcess;
const clone = @import("../container/clone.zig");
const ContainerStore = @import("../container/store.zig").ContainerStore;
const runc = @import("../runtime/runc.zig");
const fsutil = @import("../util/fsutil.zig");
const CrateError = @import("../errdefs/errors.zig").Error;

/// Registers an exec session. Returns its id, allocated with `allocator`.
pub fn containerExecCreate(daemon: *Daemon, container_name: []const u8, cmd: []const []const u8, privileged: bool, tty: bool, allocator: std.mem.Allocator) ![]const u8 {
    if (cmd.len == 0) return CrateError.InvalidParameter;
    const ctr = daemon.containers.get(container_name) orelse return CrateError.ContainerNotFound;
    defer ctr.release();

    var bytes: [32]u8 = undefined;
    try daemon.config.io.randomSecure(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);

    {
        ctr.lock();
        defer ctr.unlock();
        if (!ctr.state.running) return CrateError.ContainerNotRunning;

        // Exec sessions live as long as the container, in its arena.
        const a = ctr.allocator();
        const ep = try a.create(ExecProcess);
        ep.* = .{
            .id = try a.dupe(u8, &hex),
            .running = false,
            .tty = tty,
            .container_id = try a.dupe(u8, ctr.id[0..]),
            .cmd = try clone.strings(a, cmd),
            .privileged = privileged,
        };
        try ctr.exec_commands.put(ep.id, ep);
    }

    const now = std.Io.Clock.now(.real, daemon.config.io).toNanoseconds();
    daemon.events.publish(.{ .event_type = .container, .action = "exec_create", .actor_id = ctr.id[0..], .time_nano = now });
    return allocator.dupe(u8, &hex);
}

/// A retained container plus one of its exec sessions. Call `deinit`.
const Found = struct {
    ctr: *Container,
    ep: *ExecProcess,

    fn deinit(self: Found) void {
        self.ctr.release();
    }
};

fn find(daemon: *Daemon, exec_id: []const u8) !Found {
    const list = try daemon.containers.list(daemon.allocator);
    defer ContainerStore.releaseList(daemon.allocator, list);
    for (list) |ctr| {
        ctr.lock();
        defer ctr.unlock();
        if (ctr.exec_commands.get(exec_id)) |ep| return .{ .ctr = ctr.retain(), .ep = ep };
    }
    return CrateError.ExecNotFound;
}

/// Starts a detached exec. Output is discarded until hijacked streams land
/// (Phase 1/3); the exit code is recorded for exec inspect.
pub fn containerExecStart(daemon: *Daemon, exec_id: []const u8) !void {
    const f = try find(daemon, exec_id);
    defer f.deinit();
    const io = daemon.config.io;

    var spec_path_buf: [512]u8 = undefined;
    var spec_path: []const u8 = undefined;
    {
        f.ctr.lock();
        defer f.ctr.unlock();
        if (!f.ctr.state.running) return CrateError.ContainerNotRunning;
        if (f.ep.running) return CrateError.ContainerAlreadyRunning;

        var dir_buf: [256]u8 = undefined;
        const bundle = try daemon.config.bundleDir(f.ctr.id[0..], &dir_buf);
        spec_path = try std.fmt.bufPrint(&spec_path_buf, "{s}/exec-{s}.json", .{ bundle, f.ep.id });
        const process = .{
            .terminal = false,
            .user = .{ .uid = 0, .gid = 0 },
            .args = f.ep.cmd,
            .env = f.ctr.config.env,
            .cwd = if (f.ctr.config.working_dir.len > 0) f.ctr.config.working_dir else "/",
        };
        try fsutil.writeJsonAtomic(io, daemon.allocator, spec_path, process);
    }

    var child = try runc.exec(io, f.ctr.id[0..], spec_path);

    f.ctr.lock();
    f.ep.pid = if (child.id) |pid| @intCast(pid) else 0;
    f.ep.running = true;
    f.ctr.unlock();

    const owned: Found = .{ .ctr = f.ctr.retain(), .ep = f.ep };
    const thread = std.Thread.spawn(.{}, reap, .{ daemon, owned, child }) catch |err| {
        owned.deinit();
        child.kill(io);
        return err;
    };
    thread.detach();

    const now = std.Io.Clock.now(.real, io).toNanoseconds();
    daemon.events.publish(.{ .event_type = .container, .action = "exec_start", .actor_id = f.ctr.id[0..], .time_nano = now });
}

/// Takes ownership of `f`'s reference.
fn reap(daemon: *Daemon, f: Found, child: std.process.Child) void {
    defer f.deinit();
    var c = child;
    const term = c.wait(daemon.config.io) catch null;
    f.ctr.lock();
    defer f.ctr.unlock();
    f.ep.running = false;
    f.ep.exit_code = if (term) |t| switch (t) {
        .exited => |code| code,
        .signal => |sig| 128 + @as(i32, @intCast(@intFromEnum(sig))),
        else => 255,
    } else 255;
}

pub const ExecInfo = struct {
    id: [64]u8,
    container_id: [64]u8,
    running: bool,
    exit_code: i32,
    pid: u32,
};

/// Snapshot of an exec session, safe to use after the container is gone.
pub fn containerExecInspect(daemon: *Daemon, exec_id: []const u8) !ExecInfo {
    const f = try find(daemon, exec_id);
    defer f.deinit();
    f.ctr.lock();
    defer f.ctr.unlock();
    var info: ExecInfo = .{ .id = @splat(0), .container_id = f.ctr.id, .running = f.ep.running, .exit_code = f.ep.exit_code, .pid = f.ep.pid };
    @memcpy(info.id[0..@min(64, f.ep.id.len)], f.ep.id[0..@min(64, f.ep.id.len)]);
    return info;
}

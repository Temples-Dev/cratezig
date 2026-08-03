const std = @import("std");

pub const RuncState = struct {
    id: []const u8,
    pid: u32,
    status: []const u8, // "created", "running", "stopped"
    bundle: []const u8,
};

pub const ParsedState = struct {
    raw_stdout: []u8,
    parsed: std.json.Parsed(RuncState),
    pub fn deinit(self: ParsedState, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.raw_stdout);
    }
};

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runCmd(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !RunResult {
    var proc = try std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    
    var stdout_buf: [1024]u8 = undefined;
    var stdout_reader = proc.stdout.?.reader(io, &stdout_buf);
    const stdout = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(stdout);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_reader = proc.stderr.?.reader(io, &stderr_buf);
    const stderr = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(stderr);

    const term = try proc.wait(io);
    return RunResult{
        .stdout = stdout,
        .stderr = stderr,
        .term = term,
    };
}

pub fn create(io: std.Io, container_id: []const u8, bundle_dir: []const u8, allocator: std.mem.Allocator) !void {
    const result = try runCmd(io, allocator, &.{ "runc", "create", "--bundle", bundle_dir, container_id });
    defer result.deinit(allocator);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("runc create failed: {s}", .{result.stderr});
        return error.RuntimeError;
    }
}

pub fn start(io: std.Io, container_id: []const u8, allocator: std.mem.Allocator) !u32 {
    const result = try runCmd(io, allocator, &.{ "runc", "start", container_id });
    defer result.deinit(allocator);

    if (result.term != .exited or result.term.exited != 0) {
        return error.RuntimeError;
    }

    const state = try getState(io, container_id, allocator);
    defer state.deinit(allocator);
    return state.parsed.value.pid;
}

pub fn getState(io: std.Io, container_id: []const u8, allocator: std.mem.Allocator) !ParsedState {
    const result = try runCmd(io, allocator, &.{ "runc", "state", container_id });
    errdefer result.deinit(allocator);

    if (result.term != .exited or result.term.exited != 0) {
        result.deinit(allocator);
        return error.RuntimeError;
    }

    var state_wrapper = ParsedState{
        .raw_stdout = result.stdout,
        .parsed = undefined,
    };
    errdefer allocator.free(state_wrapper.raw_stdout);
    allocator.free(result.stderr);

    state_wrapper.parsed = try std.json.parseFromSlice(RuncState, allocator, state_wrapper.raw_stdout, .{ .ignore_unknown_fields = true });
    return state_wrapper;
}

pub fn kill(io: std.Io, container_id: []const u8, signal: []const u8, allocator: std.mem.Allocator) !void {
    const result = try runCmd(io, allocator, &.{ "runc", "kill", container_id, signal });
    defer result.deinit(allocator);

    if (result.term != .exited or result.term.exited != 0) {
        return error.RuntimeError;
    }
}

pub fn wait(io: std.Io, container_id: []const u8, allocator: std.mem.Allocator) !i32 {
    while (true) {
        const state = getState(io, container_id, allocator) catch return 137;
        defer state.deinit(allocator);
        if (std.mem.eql(u8, state.parsed.value.status, "stopped")) {
            break;
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
    }

    const result = try runCmd(io, allocator, &.{ "runc", "delete", container_id });
    defer result.deinit(allocator);

    return 0;
}

pub fn execInContainer(io: std.Io, container_id: []const u8, process_spec_path: []const u8) !u32 {
    const proc = try std.process.spawn(io, .{
        .argv = &.{ "runc", "exec", "--process", process_spec_path, container_id },
        .stdout = .pipe,
        .stderr = .pipe,
    });
    return @intCast(proc.id.?);
}

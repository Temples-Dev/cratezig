//! Thin wrapper around the runc CLI. All state lives under `<exec-root>/runc`
//! so cratezig never touches containers owned by Docker or containerd.
const std = @import("std");

/// Set once by `configure` at daemon startup, before any thread starts.
var binary: []const u8 = "runc";
var runc_root: []const u8 = "/run/cratezig/runc";

pub fn configure(runc_binary: []const u8, root: []const u8) void {
    binary = runc_binary;
    runc_root = root;
}

pub const RuncState = struct {
    id: []const u8,
    pid: u32,
    status: []const u8, // "created", "running", "paused", "stopped"
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

    fn ok(self: RunResult) bool {
        return self.term == .exited and self.term.exited == 0;
    }

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Runs `runc --root <runc_root> <args...>` and collects its output. Only for
/// subcommands that do not hand their stdio to a container process.
fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !RunResult {
    var argv_buf: [16][]const u8 = undefined;
    if (args.len + 3 > argv_buf.len) return error.InvalidParameter;
    argv_buf[0] = binary;
    argv_buf[1] = "--root";
    argv_buf[2] = runc_root;
    @memcpy(argv_buf[3 .. 3 + args.len], args);

    var proc = try std.process.spawn(io, .{
        .argv = argv_buf[0 .. 3 + args.len],
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout_buf: [1024]u8 = undefined;
    var stdout_reader = proc.stdout.?.reader(io, &stdout_buf);
    const stdout = try stdout_reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024));
    errdefer allocator.free(stdout);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_reader = proc.stderr.?.reader(io, &stderr_buf);
    const stderr = try stderr_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    errdefer allocator.free(stderr);

    return .{ .stdout = stdout, .stderr = stderr, .term = try proc.wait(io) };
}

fn runChecked(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const result = try run(io, allocator, args);
    defer result.deinit(allocator);
    if (!result.ok()) {
        std.log.err("runc {s} failed: {s}", .{ args[0], std.mem.trim(u8, result.stderr, " \n") });
        return error.RuntimeError;
    }
}

/// `runc create`. The container's stdout/stderr go to `output` (a file owned
/// by the caller); runc's own diagnostics go to `<bundle>/runc.log`. Pipes
/// must not be used here: the container inherits them and they never close.
pub fn create(io: std.Io, container_id: []const u8, bundle_dir: []const u8, output: std.Io.File) !void {
    var log_buf: [512]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "{s}/runc.log", .{bundle_dir});

    var proc = try std.process.spawn(io, .{
        .argv = &.{ binary, "--root", runc_root, "--log", log_path, "create", "--bundle", bundle_dir, container_id },
        .stdin = .ignore,
        .stdout = .{ .file = output },
        .stderr = .{ .file = output },
    });
    const term = try proc.wait(io);
    if (term != .exited or term.exited != 0) {
        std.log.err("runc create {s} failed, see {s}", .{ container_id[0..@min(12, container_id.len)], log_path });
        return error.RuntimeError;
    }
}

pub fn start(io: std.Io, container_id: []const u8, allocator: std.mem.Allocator) !void {
    try runChecked(io, allocator, &.{ "start", container_id });
}

pub fn getState(io: std.Io, container_id: []const u8, allocator: std.mem.Allocator) !ParsedState {
    const result = try run(io, allocator, &.{ "state", container_id });
    if (!result.ok()) {
        result.deinit(allocator);
        return error.RuntimeError;
    }
    allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    return .{
        .raw_stdout = result.stdout,
        .parsed = try std.json.parseFromSlice(RuncState, allocator, result.stdout, .{ .ignore_unknown_fields = true }),
    };
}

pub fn kill(io: std.Io, container_id: []const u8, signal: []const u8, allocator: std.mem.Allocator) !void {
    try runChecked(io, allocator, &.{ "kill", container_id, signal });
}

pub fn pause(io: std.Io, container_id: []const u8, allocator: std.mem.Allocator) !void {
    try runChecked(io, allocator, &.{ "pause", container_id });
}

pub fn unpause(io: std.Io, container_id: []const u8, allocator: std.mem.Allocator) !void {
    try runChecked(io, allocator, &.{ "resume", container_id });
}

/// Removes runc's record of the container. `force` also kills it if needed.
pub fn delete(io: std.Io, container_id: []const u8, allocator: std.mem.Allocator, force: bool) !void {
    if (force) {
        try runChecked(io, allocator, &.{ "delete", "--force", container_id });
    } else {
        try runChecked(io, allocator, &.{ "delete", container_id });
    }
}

/// Starts `runc exec` detached from the daemon's stdio. Returns the runc
/// process; the caller owns waiting on it.
pub fn exec(io: std.Io, container_id: []const u8, process_spec_path: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ binary, "--root", runc_root, "exec", "--process", process_spec_path, container_id },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

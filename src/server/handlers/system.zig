const std = @import("std");
const builtin = @import("builtin");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const Daemon = @import("../../daemon/daemon.zig").Daemon;

pub fn handlePing(req: Request, alloc: std.mem.Allocator) !Response {
    _ = req;
    _ = alloc;
    return Response{
        .status = 200,
        .content_type = "text/plain",
        .body = "OK",
    };
}

pub const engine_version = "24.0.0-cratezig";
pub const api_version = "1.43";
pub const min_api_version = "1.24";

fn goArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .arm => "arm",
        .riscv64 => "riscv64",
        else => @tagName(builtin.cpu.arch),
    };
}

pub fn handleVersion(req: Request, alloc: std.mem.Allocator) !Response {
    _ = req;
    var uts: std.os.linux.utsname = undefined;
    _ = std.os.linux.uname(&uts);
    const kernel = std.mem.sliceTo(&uts.release, 0);
    const details = .{
        .ApiVersion = api_version,
        .MinAPIVersion = min_api_version,
        .GitCommit = "",
        .GoVersion = "zig " ++ builtin.zig_version_string,
        .Os = "linux",
        .Arch = goArch(),
        .KernelVersion = kernel,
    };
    const body = try std.json.Stringify.valueAlloc(alloc, .{
        .Platform = .{ .Name = "Cratezig Engine" },
        .Components = .{.{ .Name = "Engine", .Version = engine_version, .Details = details }},
        .Version = engine_version,
        .ApiVersion = api_version,
        .MinAPIVersion = min_api_version,
        .GitCommit = "",
        .GoVersion = details.GoVersion,
        .Os = "linux",
        .Arch = goArch(),
        .KernelVersion = kernel,
    }, .{});
    return Response.ok(body);
}

pub fn handleInfo(req: Request, alloc: std.mem.Allocator) !Response {
    _ = req;
    const body = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "ID": "CRATEZIG-DAEMON-01",
        \\  "Containers": 0,
        \\  "ContainersRunning": 0,
        \\  "ContainersPaused": 0,
        \\  "ContainersStopped": 0,
        \\  "Images": 0,
        \\  "Driver": "overlay2",
        \\  "LoggingDriver": "json-file",
        \\  "CgroupDriver": "systemd",
        \\  "CgroupVersion": "2",
        \\  "KernelVersion": "6.5.0-generic",
        \\  "OperatingSystem": "Linux (Cratezig Engine)",
        \\  "OSType": "linux",
        \\  "Architecture": "x86_64"
        \\}}
    , .{});

    return Response{
        .status = 200,
        .content_type = "application/json",
        .body = body,
    };
}

pub fn ping(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    return handlePing(req.*, alloc) catch Response.internalError("ping failed");
}

pub fn version(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    return handleVersion(req.*, alloc) catch Response.internalError("version failed");
}

pub fn info(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    return handleInfo(req.*, alloc) catch Response.internalError("info failed");
}

pub fn events(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.ok("{}");
}

pub fn diskUsage(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.ok("{}");
}

test "system discovery endpoints serialization" {
    const alloc = std.testing.allocator;
    var req = Request.init(alloc);
    defer req.deinit();
    req.method = "GET";
    req.path = "/version";

    const ver_resp = try handleVersion(req, alloc);
    defer alloc.free(ver_resp.body);

    try std.testing.expectEqual(@as(u16, 200), ver_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, ver_resp.body, "\"ApiVersion\":\"1.43\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ver_resp.body, "\"MinAPIVersion\":\"1.24\"") != null);
}

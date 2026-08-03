const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

pub fn ping(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.ok("OK");
}

pub fn version(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.ok("{\"Version\":\"0.1.0\",\"ApiVersion\":\"1.47\",\"MinAPIVersion\":\"1.12\",\"GitCommit\":\"cratezig-dev\",\"GoVersion\":\"zig0.16.0\",\"Os\":\"linux\",\"Arch\":\"amd64\"}");
}

pub fn info(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.ok("{\"ID\":\"cratezig-daemon\",\"Containers\":0,\"Images\":0,\"Driver\":\"overlay2\"}");
}

pub fn events(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.internalError("not implemented");
}

pub fn diskUsage(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.internalError("not implemented");
}

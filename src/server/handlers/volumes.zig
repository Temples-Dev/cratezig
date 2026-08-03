const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

pub fn list(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.internalError("not implemented");
}

pub fn create(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.internalError("not implemented");
}

pub fn inspect(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.internalError("not implemented");
}

pub fn remove(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.internalError("not implemented");
}

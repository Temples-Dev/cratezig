const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

pub fn list(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = req;
    const images = daemon.images.list(alloc) catch |err| {
        return Response.fromError(err);
    };
    defer alloc.free(images);

    const json = std.json.Stringify.valueAlloc(alloc, images, .{}) catch "[]";
    return Response.ok(json);
}

pub fn pull(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const from_image = req.query.get("fromImage") orelse return Response.badRequest("missing fromImage");
    const tag_val = req.query.get("tag") orelse "latest";

    _ = daemon.images.pullImage(from_image, tag_val) catch |err| {
        if (err == error.NotImplemented) return Response.notImplemented("image pull is not supported by cratezig yet");
        return Response.fromError(err);
    };

    const status = std.fmt.allocPrint(alloc, "Status: Image is up to date for {s}:{s}", .{ from_image, tag_val }) catch return Response.internalError("out of memory");
    const body = std.json.Stringify.valueAlloc(alloc, .{ .status = status }, .{}) catch return Response.internalError("out of memory");
    return Response.ok(body);
}

pub fn inspect(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const img = daemon.images.getImage(name) catch |err| {
        return Response.fromError(err);
    };

    const json = std.json.Stringify.valueAlloc(alloc, img.*, .{}) catch "{}";
    return Response.ok(json);
}

pub fn remove(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const force = req.queryBool("force");
    const report = daemon.images.removeImage(alloc, name, force) catch |err| {
        return Response.fromError(err);
    };

    const json = std.json.Stringify.valueAlloc(alloc, report, .{}) catch "[]";
    return Response.ok(json);
}

pub fn tag(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const repo = req.query.get("repo") orelse return Response.badRequest("missing repo");
    const tag_val = req.query.get("tag") orelse "latest";

    daemon.images.tagImage(name, repo, tag_val) catch |err| {
        return Response.fromError(err);
    };
    return Response.created("");
}

pub fn push(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.notImplemented("image push is not supported by cratezig yet");
}

pub fn history(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.ok("[]");
}

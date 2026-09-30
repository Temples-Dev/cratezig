const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const ContainerStore = @import("../../container/store.zig").ContainerStore;

pub fn list(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = req;
    const images = daemon.images.list(alloc) catch |err| {
        return Response.fromError(err);
    };
    defer alloc.free(images);

    const json = std.json.Stringify.valueAlloc(alloc, images, .{}) catch "[]";
    return Response.ok(json);
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

    // Image ids referenced by any container (running or not).
    const containers = daemon.containers.list(alloc) catch return Response.internalError("out of memory");
    defer ContainerStore.releaseList(alloc, containers);
    const in_use = alloc.alloc([]const u8, containers.len) catch return Response.internalError("out of memory");
    for (containers, 0..) |c, i| in_use[i] = c.image_id; // immutable after create

    const report = daemon.images.removeImage(alloc, name, force, in_use) catch |err| {
        if (err == error.ImageInUse) return Response.conflict(std.fmt.allocPrint(alloc, "conflict: unable to remove repository reference \"{s}\" - image is being used by a container", .{name}) catch "image is in use");
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

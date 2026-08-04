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
    _ = alloc;
    const from_image = req.query.get("fromImage") orelse return Response.badRequest("missing fromImage");
    const tag_val = req.query.get("tag") orelse "latest";

    _ = daemon.images.pullImage(from_image, tag_val) catch |err| {
        return Response.fromError(err);
    };
    return Response.ok("");
}

pub fn inspect(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const img = daemon.images.getImage(name) catch |err| {
        return Response.fromError(err);
    };

    const json = std.json.Stringify.valueAlloc(alloc, img.*, .{}) catch "{}";
    return Response.ok(json);
}

pub fn handlePruneImages(req: Request, alloc: std.mem.Allocator) !Response {
    _ = req;
    var out_buf = std.ArrayList(u8).empty;
    errdefer out_buf.deinit(alloc);

    var jws = std.json.writeStream(out_buf.writer(alloc), .{});
    defer jws.deinit();

    try jws.beginObject();
    try jws.objectField("ImagesDeleted");
    try jws.beginArray();
    try jws.endArray();

    try jws.objectField("SpaceReclaimed");
    try jws.write(@as(u64, 0));
    try jws.endObject();

    return Response{
        .status = .ok,
        .content_type = "application/json",
        .body = try out_buf.toOwnedSlice(alloc),
    };
}

pub fn remove(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const force = if (req.query.get("force")) |f| std.mem.eql(u8, f, "true") else false;
    const noprune = if (req.query.get("noprune")) |n| std.mem.eql(u8, n, "true") else false;

    const report = daemon.images.removeImage(name, force, noprune) catch |err| {
        return Response.fromError(err);
    };
    defer {
        for (report) |item| {
            if (item.untagged) |u| alloc.free(u);
            if (item.deleted) |d| alloc.free(d);
        }
        alloc.free(report);
    }

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
    return Response.ok("push successful");
}

pub fn history(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.ok("[]");
}

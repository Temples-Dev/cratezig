const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

const Image = @import("../../image/types.zig").Image;
const Container = @import("../../container/container.zig").Container;
const Volume = @import("../../volume/types.zig").Volume;

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
    const since_str = req.query.get("since") orelse "";
    const until_str = req.query.get("until") orelse "";

    const since_val = std.fmt.parseInt(i64, since_str, 10) catch @as(i64, 0);
    const until_val = std.fmt.parseInt(i64, until_str, 10) catch @as(i64, 0);

    const list = daemon.events.getEvents(alloc) catch |err| {
        return Response.fromError(err);
    };
    defer alloc.free(list);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    for (list) |e| {
        const sec = @divTrunc(e.time_nano, 1_000_000_000);
        if (sec < since_val) continue;
        if (until_val > 0 and sec > until_val) continue;

        const item_json = std.json.Stringify.valueAlloc(alloc, e, .{}) catch continue;
        defer alloc.free(item_json);

        buf.appendSlice(alloc, item_json) catch {};
        buf.append(alloc, '\n') catch {};
    }

    const body = alloc.dupe(u8, buf.items) catch "";
    return Response.ok(body);
}

const DiskUsageResponse = struct {
    LayersSize: i64 = 0,
    Images: []const *const Image = &.{},
    Containers: []const *const Container = &.{},
    Volumes: []const *const Volume = &.{},
};

pub fn diskUsage(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = req;
    const images = daemon.images.list(alloc) catch |err| {
        return Response.fromError(err);
    };
    defer alloc.free(images);

    const containers = daemon.containers.list(alloc) catch |err| {
        return Response.fromError(err);
    };
    defer alloc.free(containers);

    const volumes = daemon.volumes.list(alloc) catch |err| {
        return Response.fromError(err);
    };
    defer alloc.free(volumes);

    const response = DiskUsageResponse{
        .LayersSize = 0,
        .Images = @ptrCast(images),
        .Containers = @ptrCast(containers),
        .Volumes = @ptrCast(volumes),
    };

    const json = std.json.Stringify.valueAlloc(alloc, response, .{}) catch "{}";
    return Response.ok(json);
}

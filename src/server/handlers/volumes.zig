const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

const VolumeListResponse = struct {
    Volumes: []const *const Volume = &.{},
    Warnings: []const []const u8 = &.{},
};

const Volume = @import("../../volume/types.zig").Volume;

pub fn list(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = req;
    const volumes = daemon.volumes.list(alloc) catch |err| {
        return Response.fromError(err);
    };
    defer alloc.free(volumes);

    const response = VolumeListResponse{
        .Volumes = @ptrCast(volumes),
    };

    const json = std.json.Stringify.valueAlloc(alloc, response, .{}) catch "{\"Volumes\":[],\"Warnings\":[]}";
    return Response.ok(json);
}

pub fn create(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const body = req.body;
    if (body.len == 0) return Response.badRequest("missing body");

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return Response.badRequest("invalid json");
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return Response.badRequest("invalid json"),
    };

    const name = if (root.get("Name")) |v| v.string else return Response.badRequest("missing Name");
    const driver = if (root.get("Driver")) |v| v.string else "local";

    var labels = std.StringHashMap([]const u8).init(alloc);
    defer labels.deinit();
    if (root.get("Labels")) |l| {
        if (l == .object) {
            var it = l.object.iterator();
            while (it.next()) |entry| {
                labels.put(entry.key_ptr.*, entry.value_ptr.*.string) catch {};
            }
        }
    }

    var options = std.StringHashMap([]const u8).init(alloc);
    defer options.deinit();
    if (root.get("DriverOpts")) |o| {
        if (o == .object) {
            var it = o.object.iterator();
            while (it.next()) |entry| {
                options.put(entry.key_ptr.*, entry.value_ptr.*.string) catch {};
            }
        }
    }

    const vol = daemon.volumes.createVolume(name, driver, labels, options) catch |err| {
        return Response.fromError(err);
    };

    const json = std.json.Stringify.valueAlloc(alloc, vol.*, .{}) catch "{}";
    return Response.created(json);
}

pub fn inspect(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const vol = daemon.volumes.get(name) orelse return Response.notFound("volume not found");

    const json = std.json.Stringify.valueAlloc(alloc, vol.*, .{}) catch "{}";
    return Response.ok(json);
}

pub fn remove(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const force = if (req.query.get("force")) |f| std.mem.eql(u8, f, "true") else false;

    daemon.volumes.deleteVolume(name, force) catch |err| {
        return Response.fromError(err);
    };
    return Response.noContent();
}

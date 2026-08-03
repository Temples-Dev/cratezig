const std = @import("std");
const Daemon = @import("../daemon/daemon.zig").Daemon;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const PathParams = @import("request.zig").PathParams;

const ch = @import("handlers/container.zig");
const ih = @import("handlers/images.zig");
const nh = @import("handlers/networks.zig");
const vh = @import("handlers/volumes.zig");
const sh = @import("handlers/system.zig");

const Handler = *const fn (daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response;

const Route = struct {
    method: []const u8,
    pattern: []const u8,
    handler: Handler,
};

// The complete route table.
const ROUTES = [_]Route{
    // ── System ──────────────────────────────────────────────────────────────
    .{ .method = "GET", .pattern = "/_ping", .handler = sh.ping },
    .{ .method = "GET", .pattern = "/version", .handler = sh.version },
    .{ .method = "GET", .pattern = "/info", .handler = sh.info },
    .{ .method = "GET", .pattern = "/events", .handler = sh.events },
    .{ .method = "GET", .pattern = "/df", .handler = sh.diskUsage },

    // ── Containers ───────────────────────────────────────────────────────────
    .{ .method = "GET", .pattern = "/containers/json", .handler = ch.list },
    .{ .method = "POST", .pattern = "/containers/create", .handler = ch.create },
    .{ .method = "POST", .pattern = "/containers/{name}/start", .handler = ch.start },
    .{ .method = "POST", .pattern = "/containers/{name}/stop", .handler = ch.stop },
    .{ .method = "POST", .pattern = "/containers/{name}/restart", .handler = ch.restart },
    .{ .method = "POST", .pattern = "/containers/{name}/kill", .handler = ch.kill },
    .{ .method = "POST", .pattern = "/containers/{name}/pause", .handler = ch.pause },
    .{ .method = "POST", .pattern = "/containers/{name}/unpause", .handler = ch.unpause },
    .{ .method = "POST", .pattern = "/containers/{name}/wait", .handler = ch.wait },
    .{ .method = "GET", .pattern = "/containers/{name}/json", .handler = ch.inspect },
    .{ .method = "GET", .pattern = "/containers/{name}/logs", .handler = ch.logs },
    .{ .method = "GET", .pattern = "/containers/{name}/stats", .handler = ch.stats },
    .{ .method = "POST", .pattern = "/containers/{name}/exec", .handler = ch.execCreate },
    .{ .method = "POST", .pattern = "/exec/{id}/start", .handler = ch.execStart },
    .{ .method = "DELETE", .pattern = "/containers/{name}", .handler = ch.remove },
    .{ .method = "POST", .pattern = "/containers/prune", .handler = ch.prune },

    // ── Images ──────────────────────────────────────────────────────────────
    .{ .method = "GET", .pattern = "/images/json", .handler = ih.list },
    .{ .method = "POST", .pattern = "/images/create", .handler = ih.pull },
    .{ .method = "GET", .pattern = "/images/{name}/json", .handler = ih.inspect },
    .{ .method = "DELETE", .pattern = "/images/{name}", .handler = ih.remove },
    .{ .method = "POST", .pattern = "/images/{name}/tag", .handler = ih.tag },
    .{ .method = "POST", .pattern = "/images/{name}/push", .handler = ih.push },
    .{ .method = "GET", .pattern = "/images/{name}/history", .handler = ih.history },

    // ── Networks ─────────────────────────────────────────────────────────────
    .{ .method = "GET", .pattern = "/networks", .handler = nh.list },
    .{ .method = "GET", .pattern = "/networks/{id}", .handler = nh.inspect },
    .{ .method = "POST", .pattern = "/networks/create", .handler = nh.create },
    .{ .method = "DELETE", .pattern = "/networks/{id}", .handler = nh.remove },
    .{ .method = "POST", .pattern = "/networks/{id}/connect", .handler = nh.connect },
    .{ .method = "POST", .pattern = "/networks/{id}/disconnect", .handler = nh.disconnect },

    // ── Volumes ──────────────────────────────────────────────────────────────
    .{ .method = "GET", .pattern = "/volumes", .handler = vh.list },
    .{ .method = "POST", .pattern = "/volumes/create", .handler = vh.create },
    .{ .method = "GET", .pattern = "/volumes/{name}", .handler = vh.inspect },
    .{ .method = "DELETE", .pattern = "/volumes/{name}", .handler = vh.remove },
};

pub fn dispatch(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const path = stripVersion(req.path);

    for (ROUTES) |route| {
        if (!std.mem.eql(u8, route.method, req.method)) continue;
        if (matchPattern(route.pattern, path, &req.params)) {
            return route.handler(daemon, req, alloc);
        }
    }

    return Response.notFound("no route matched");
}

fn stripVersion(path: []const u8) []const u8 {
    if (path.len > 1 and path[1] == 'v') {
        if (std.mem.indexOf(u8, path[1..], "/")) |pos| {
            return path[1 + pos ..];
        }
    }
    return path;
}

fn matchPattern(pattern: []const u8, path: []const u8, params: *PathParams) bool {
    var pat = std.mem.splitScalar(u8, pattern, '/');
    var seg = std.mem.splitScalar(u8, path, '/');

    while (true) {
        const p = pat.next();
        const s = seg.next();
        if (p == null and s == null) return true;
        if (p == null or s == null) return false;
        if (p.?.len > 0 and p.?[0] == '{' and p.?[p.?.len - 1] == '}') {
            const key = p.?[1 .. p.?.len - 1];
            params.put(key, s.?) catch {};
        } else {
            if (!std.mem.eql(u8, p.?, s.?)) return false;
        }
    }
}

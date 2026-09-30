const std = @import("std");
const Daemon = @import("../daemon/daemon.zig").Daemon;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const PathParams = @import("request.zig").PathParams;

const ch = @import("handlers/container.zig");
const cc = @import("handlers/container_create.zig");
const ih = @import("handlers/images.zig");
const nh = @import("handlers/networks.zig");
const vh = @import("handlers/volumes.zig");
const sh = @import("handlers/system.zig");
const bh = @import("handlers/builder_handler.zig");
const eh = @import("handlers/events.zig");
const pullh = @import("handlers/image_pull.zig");

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
    .{ .method = "GET", .pattern = "/events", .handler = eh.stream },
    .{ .method = "GET", .pattern = "/system/df", .handler = sh.diskUsage },
    .{ .method = "POST", .pattern = "/build", .handler = bh.build },

    // ── Containers ───────────────────────────────────────────────────────────
    .{ .method = "GET", .pattern = "/containers/json", .handler = ch.list },
    .{ .method = "POST", .pattern = "/containers/create", .handler = cc.create },
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
    .{ .method = "POST", .pattern = "/images/create", .handler = pullh.pull },
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

pub const max_api_version: u32 = 43;
pub const min_api_version: u32 = 24;

pub fn dispatch(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const split = splitVersion(req.path) catch return Response.badRequest("malformed API version in path");
    if (split.minor) |minor| {
        if (minor > max_api_version) return Response.badRequest(std.fmt.allocPrint(alloc, "client version 1.{d} is too new. Maximum supported API version is 1.{d}", .{ minor, max_api_version }) catch "client version too new");
        if (minor < min_api_version) return Response.badRequest(std.fmt.allocPrint(alloc, "client version 1.{d} is too old. Minimum supported API version is 1.{d}", .{ minor, min_api_version }) catch "client version too old");
    }
    const path = split.path;
    const method = if (std.mem.eql(u8, req.method, "HEAD")) "GET" else req.method;

    // Literal routes win over parameterised ones ("/containers/json" vs "/containers/{name}").
    for ([_]bool{ false, true }) |want_params| {
        for (ROUTES) |route| {
            const has_params = std.mem.indexOfScalar(u8, route.pattern, '{') != null;
            if (has_params != want_params or !std.mem.eql(u8, route.method, method)) continue;
            var params = PathParams{};
            if (matchPattern(route.pattern, path, &params)) {
                req.params = params;
                return route.handler(daemon, req, alloc);
            }
        }
    }
    return Response.notFound("page not found");
}

const VersionSplit = struct { path: []const u8, minor: ?u32 };

/// "/v1.43/containers/json" -> ("/containers/json", 43). Only "/v<digit>"
/// counts as a version prefix; "/volumes" is a normal path.
fn splitVersion(path: []const u8) !VersionSplit {
    if (path.len < 3 or path[1] != 'v' or !std.ascii.isDigit(path[2])) return .{ .path = path, .minor = null };
    const end = std.mem.indexOfScalarPos(u8, path, 1, '/') orelse path.len;
    const ver = path[2..end];
    const dot = std.mem.indexOfScalar(u8, ver, '.') orelse return error.BadVersion;
    if (!std.mem.eql(u8, ver[0..dot], "1")) return error.BadVersion;
    const minor = std.fmt.parseInt(u32, ver[dot + 1 ..], 10) catch return error.BadVersion;
    return .{ .path = if (end == path.len) "/" else path[end..], .minor = minor };
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
            if (s.?.len == 0) return false;
            params.put(p.?[1 .. p.?.len - 1], s.?) catch return false;
        } else {
            if (!std.mem.eql(u8, p.?, s.?)) return false;
        }
    }
}

test "splitVersion only strips real version prefixes" {
    try std.testing.expectEqualStrings("/volumes/x", (try splitVersion("/volumes/x")).path);
    const v = try splitVersion("/v1.43/volumes/x");
    try std.testing.expectEqualStrings("/volumes/x", v.path);
    try std.testing.expectEqual(@as(?u32, 43), v.minor);
    try std.testing.expectError(error.BadVersion, splitVersion("/v2/x"));
}

test "literal routes beat parameterised ones and params are captured" {
    var params = PathParams{};
    try std.testing.expect(matchPattern("/containers/{name}/start", "/containers/web/start", &params));
    try std.testing.expectEqualStrings("web", params.get("name").?);
    try std.testing.expect(!matchPattern("/containers/{name}", "/containers/", &params));
}

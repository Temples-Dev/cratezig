const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

pub fn list(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = req;
    const networks = daemon.network.list(alloc) catch |err| {
        return Response.fromError(err);
    };
    defer alloc.free(networks);

    const json = std.json.Stringify.valueAlloc(alloc, networks, .{}) catch "[]";
    return Response.ok(json);
}

pub fn inspect(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const id = req.params.get("id") orelse return Response.badRequest("missing id");
    const net = daemon.network.get(id) orelse return Response.notFound("network not found");

    const json = std.json.Stringify.valueAlloc(alloc, net.*, .{}) catch "{}";
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
    const driver = if (root.get("Driver")) |v| v.string else "bridge";

    var subnet: ?[]const u8 = null;
    var gateway: ?[]const u8 = null;

    if (root.get("IPAM")) |ipam| {
        if (ipam == .object) {
            if (ipam.object.get("Config")) |cfg| {
                if (cfg == .array and cfg.array.items.len > 0) {
                    const first = cfg.array.items[0];
                    if (first == .object) {
                        subnet = if (first.object.get("Subnet")) |s| s.string else null;
                        gateway = if (first.object.get("Gateway")) |g| g.string else null;
                    }
                }
            }
        }
    }

    const net = daemon.network.createNetwork(name, driver, subnet, gateway) catch |err| {
        return Response.fromError(err);
    };

    const json = std.json.Stringify.valueAlloc(alloc, net.*, .{}) catch "{}";
    return Response.created(json);
}

pub fn remove(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const id = req.params.get("id") orelse return Response.badRequest("missing id");
    daemon.network.deleteNetwork(id) catch |err| {
        return Response.fromError(err);
    };
    return Response.noContent();
}

pub fn connect(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const net_id = req.params.get("id") orelse return Response.badRequest("missing id");
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

    const container_id = if (root.get("Container")) |v| v.string else return Response.badRequest("missing Container");

    const ctr = daemon.containers.get(container_id) orelse return Response.notFound("container not found");

    ctr.lock();
    const pid = ctr.state.pid;
    const is_running = ctr.state.running;
    ctr.unlock();

    if (!is_running or pid == 0) {
        return Response.badRequest("container not running");
    }

    const net = daemon.network.get(net_id) orelse return Response.notFound("network not found");

    const ep = daemon.network.createEndpoint(net.name, ctr.id[0..], @intCast(pid)) catch |err| {
        return Response.fromError(err);
    };

    ctr.lock();
    ctr.network_settings.networks.put(net.name, ep.settings) catch |err| {
        ctr.unlock();
        return Response.fromError(err);
    };
    ctr.unlock();

    return Response.ok("");
}

pub fn disconnect(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const net_id = req.params.get("id") orelse return Response.badRequest("missing id");
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

    const container_id = if (root.get("Container")) |v| v.string else return Response.badRequest("missing Container");

    const ctr = daemon.containers.get(container_id) orelse return Response.notFound("container not found");

    const net = daemon.network.get(net_id) orelse return Response.notFound("network not found");

    ctr.lock();
    const settings_opt = ctr.network_settings.networks.get(net.name);
    ctr.unlock();

    const settings = settings_opt orelse return Response.badRequest("container not connected to network");

    daemon.network.releaseEndpoint(net.name, ctr.id[0..], settings.ip_address) catch |err| {
        return Response.fromError(err);
    };

    ctr.lock();
    _ = ctr.network_settings.networks.remove(net.name);
    ctr.unlock();

    return Response.ok("");
}

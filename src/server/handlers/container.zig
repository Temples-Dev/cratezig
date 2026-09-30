const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const start_mod = @import("../../daemon/start.zig");
const stop_mod = @import("../../daemon/stop.zig");
const remove_mod = @import("../../daemon/remove.zig");
const Container = @import("../../container/container.zig").Container;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const stream = @import("../stream.zig");
const view = @import("container_view.zig");

// POST /containers/{name}/start
pub fn start(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");

    start_mod.containerStart(daemon, name) catch |err| switch (err) {
        error.ContainerNotFound => return Response.notFound("container not found"),
        error.ContainerAlreadyRunning => return Response.notModified(),
        error.ContainerBeingRemoved => return Response.conflict("container is being removed"),
        else => return Response.fromError(err),
    };

    return Response.noContent();
}

// POST /containers/{name}/stop
pub fn stop(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const t_str = req.query.get("t");
    const timeout = if (t_str) |s| std.fmt.parseInt(u32, s, 10) catch null else null;

    stop_mod.containerStop(daemon, name, timeout) catch |err| switch (err) {
        error.ContainerNotFound => return Response.notFound("container not found"),
        else => return Response.fromError(err),
    };

    return Response.noContent();
}

// DELETE /containers/{name}
pub fn remove(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const force = req.queryBool("force");
    const remove_vols = req.queryBool("v");

    remove_mod.containerRemove(daemon, name, force, remove_vols) catch |err| switch (err) {
        error.ContainerNotFound => return Response.notFound("container not found"),
        error.ContainerAlreadyRunning => return Response.conflict("stop the container first"),
        else => return Response.fromError(err),
    };

    return Response.noContent();
}

// GET /containers/json
pub fn list(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const all = req.queryBool("all");

    const containers = daemon.containers.list(alloc) catch return Response.internalError("list failed");
    const now = std.Io.Clock.now(.real, daemon.config.io).toNanoseconds();

    var result = std.ArrayList(view.Summary).empty;
    for (containers) |ctr| {
        if (!all and !ctr.state.running) continue;
        result.append(alloc, .{ .ctr = ctr, .now_ns = now }) catch return Response.internalError("out of memory");
    }
    // Newest first, like docker ps.
    std.mem.sort(view.Summary, result.items, {}, struct {
        fn gt(_: void, a: view.Summary, b: view.Summary) bool {
            return a.ctr.created_at > b.ctr.created_at;
        }
    }.gt);

    const json = std.json.Stringify.valueAlloc(alloc, result.items, .{}) catch return Response.internalError("out of memory");
    return Response.ok(json);
}

// GET /containers/{name}/json
pub fn inspect(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const ctr = daemon.containers.get(name) orelse return Response.notFound("container not found");

    const json = std.json.Stringify.valueAlloc(alloc, ctr, .{}) catch "{}";
    return Response.ok(json);
}

// Stubs for remaining endpoints
pub fn restart(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const t_str = req.query.get("t");
    const timeout = if (t_str) |s| std.fmt.parseInt(u32, s, 10) catch null else null;

    daemon.containerRestart(name, timeout) catch |err| {
        return Response.fromError(err);
    };
    return Response.noContent();
}

pub fn kill(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const signal = req.query.get("signal");

    daemon.containerKill(name, signal) catch |err| {
        return Response.fromError(err);
    };
    return Response.noContent();
}

pub fn pause(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");

    daemon.containerPause(name) catch |err| {
        return Response.fromError(err);
    };
    return Response.noContent();
}

pub fn unpause(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");

    daemon.containerUnpause(name) catch |err| {
        return Response.fromError(err);
    };
    return Response.noContent();
}

pub fn wait(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");

    const code = daemon.containerWait(name) catch |err| {
        return Response.fromError(err);
    };

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"StatusCode\":{d}}}", .{code}) catch "{}";
    return Response.ok(json);
}

pub fn logs(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const ctr = daemon.containers.get(name) orelse return Response.notFound("container not found");
    const content = daemon.containerLogs(name, alloc) catch |err| {
        return Response.fromError(err);
    };
    // Without a TTY the CLI expects Docker's multiplexed stream framing.
    // stdout/stderr are not separated until the logging shim (Phase 3).
    if (ctr.config.tty) return .{ .status = 200, .body = content, .content_type = "application/vnd.docker.raw-stream" };
    var out = std.ArrayList(u8).empty;
    var rest = content;
    while (rest.len > 0) {
        const n = @min(rest.len, 1 << 20);
        stream.MultiplexWriter.writeFrame(alloc, &out, .stdout, rest[0..n]) catch return Response.internalError("out of memory");
        rest = rest[n..];
    }
    return .{ .status = 200, .body = out.items, .content_type = "application/vnd.docker.multiplexed-stream" };
}

pub fn stats(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const report = daemon.containerStats(name, alloc) catch |err| {
        return Response.fromError(err);
    };

    const json = std.json.Stringify.valueAlloc(alloc, report, .{}) catch "{}";
    return Response.ok(json);
}

pub fn execCreate(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const name = req.params.get("name") orelse return Response.badRequest("missing name");

    const ExecConfig = struct {
        Cmd: []const []const u8 = &.{},
        Privileged: bool = false,
        Tty: bool = false,
    };

    const parsed = std.json.parseFromSlice(ExecConfig, alloc, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return Response.badRequest("invalid body");
    };
    defer parsed.deinit();

    const exec_id = daemon.containerExecCreate(name, parsed.value.Cmd, parsed.value.Privileged, parsed.value.Tty, alloc) catch |err| {
        return Response.fromError(err);
    };

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"Id\":\"{s}\"}}", .{exec_id}) catch "{}";
    return Response.created(json);
}

pub fn execStart(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const exec_id = req.params.get("id") orelse return Response.badRequest("missing id");

    daemon.containerExecStart(exec_id) catch |err| {
        return Response.fromError(err);
    };
    return Response.noContent();
}

pub fn prune(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = req;
    const report = daemon.containerPrune(alloc) catch |err| {
        return Response.fromError(err);
    };

    const json = std.json.Stringify.valueAlloc(alloc, report, .{}) catch "{}";
    return Response.ok(json);
}

const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const create_mod = @import("../../daemon/create.zig");
const start_mod = @import("../../daemon/start.zig");
const stop_mod = @import("../../daemon/stop.zig");
const remove_mod = @import("../../daemon/remove.zig");
const Container = @import("../../container/container.zig").Container;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

// POST /containers/create
pub fn create(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const PortBinding = @import("../../container/container.zig").PortBinding;
    const JsonCreateConfig = struct {
        config: struct {
            image: []const u8,
            cmd: []const []const u8 = &.{},
            entrypoint: []const []const u8 = &.{},
            env: []const []const u8 = &.{},
            working_dir: []const u8 = "/",
            user: []const u8 = "",
            tty: bool = false,
            open_stdin: bool = false,
            stop_signal: []const u8 = "SIGTERM",
            stop_timeout: u32 = 10,
            labels: std.json.Value = .null,
            healthcheck: ?@import("../../container/container.zig").HealthCheckConfig = null,
        },
        host_config: struct {
            memory: i64 = 0,
            memory_swap: i64 = 0,
            cpu_shares: i64 = 0,
            cpu_quota: i64 = 0,
            cpu_period: i64 = 100_1000,
            pid_limits: i64 = 0,
            port_bindings: std.json.Value = .null,
            binds: []const []const u8 = &.{},
            mounts: []const []const u8 = &.{},
            network_mode: []const u8 = "bridge",
            dns: []const []const u8 = &.{},
            extra_hosts: []const []const u8 = &.{},
            privleged: bool = false,
            cap_add: []const []const u8 = &.{},
            cap_drop: []const []const u8 = &.{},
            read_only_rootfs: bool = false,
            shm_size: i64 = 67_108_864,
            init: bool = false,
            restart_policy: @import("../../container/container.zig").RestartPolicy = .{},
            ipc_mode: []const u8 = "private",
            pid_mode: []const u8 = "",
        },
        name: ?[]const u8 = null,
    };

    const cfg = std.json.parseFromSlice(JsonCreateConfig, alloc, req.body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        return Response.badRequest(std.fmt.allocPrint(alloc, "invalid body: {}", .{err}) catch "invalid body");
    };
    defer cfg.deinit();

    var labels = std.StringHashMap([]const u8).init(alloc);
    errdefer labels.deinit();
    switch (cfg.value.config.labels) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                labels.put(entry.key_ptr.*, entry.value_ptr.string) catch {};
            }
        },
        else => {},
    }

    var port_bindings = std.StringHashMap([]PortBinding).init(alloc);
    errdefer {
        var it = port_bindings.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.value_ptr.*);
        }
        port_bindings.deinit();
    }
    switch (cfg.value.host_config.port_bindings) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                var pb_list = std.array_list.AlignedManaged(PortBinding, null).init(alloc);
                defer pb_list.deinit();
                switch (entry.value_ptr.*) {
                    .array => |arr| {
                        for (arr.items) |item| {
                            var host_ip: []const u8 = "0.0.0.0";
                            var host_port: []const u8 = "";
                            switch (item) {
                                .object => |item_obj| {
                                    if (item_obj.get("HostIp")) |ip_val| {
                                        host_ip = ip_val.string;
                                    }
                                    if (item_obj.get("HostPort")) |port_val| {
                                        host_port = port_val.string;
                                    }
                                },
                                else => {},
                            }
                            pb_list.append(.{ .host_ip = host_ip, .host_port = host_port }) catch {};
                        }
                    },
                    else => {},
                }
                port_bindings.put(entry.key_ptr.*, pb_list.toOwnedSlice() catch &.{}) catch {};
            }
        },
        else => {},
    }

    const name = req.query.get("name");

    const resp = daemon.containerCreate(.{
        .config = .{
            .image = cfg.value.config.image,
            .cmd = cfg.value.config.cmd,
            .entrypoint = cfg.value.config.entrypoint,
            .env = cfg.value.config.env,
            .working_dir = cfg.value.config.working_dir,
            .user = cfg.value.config.user,
            .tty = cfg.value.config.tty,
            .open_stdin = cfg.value.config.open_stdin,
            .stop_signal = cfg.value.config.stop_signal,
            .stop_timeout = cfg.value.config.stop_timeout,
            .labels = labels,
            .healthcheck = cfg.value.config.healthcheck,
        },
        .host_config = .{
            .memory = cfg.value.host_config.memory,
            .memory_swap = cfg.value.host_config.memory_swap,
            .cpu_shares = cfg.value.host_config.cpu_shares,
            .cpu_quota = cfg.value.host_config.cpu_quota,
            .cpu_period = cfg.value.host_config.cpu_period,
            .pid_limits = cfg.value.host_config.pid_limits,
            .port_bindings = port_bindings,
            .binds = cfg.value.host_config.binds,
            .mounts = cfg.value.host_config.mounts,
            .network_mode = cfg.value.host_config.network_mode,
            .dns = cfg.value.host_config.dns,
            .extra_hosts = cfg.value.host_config.extra_hosts,
            .privleged = cfg.value.host_config.privleged,
            .cap_add = cfg.value.host_config.cap_add,
            .cap_drop = cfg.value.host_config.cap_drop,
            .read_only_rootfs = cfg.value.host_config.read_only_rootfs,
            .shm_size = cfg.value.host_config.shm_size,
            .init = cfg.value.host_config.init,
            .restart_policy = cfg.value.host_config.restart_policy,
            .ipc_mode = cfg.value.host_config.ipc_mode,
            .pid_mode = cfg.value.host_config.pid_mode,
        },
        .name = name,
    }, alloc) catch |err| {
        return Response.fromError(err);
    };

    const json = std.json.Stringify.valueAlloc(alloc, resp, .{}) catch "{}";
    return Response.created(json);
}

// POST /containers/{name}/start
pub fn start(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");

    start_mod.containerStart(daemon, name) catch |err| switch (err) {
        error.ContainerNotFound => return Response.notFound("container not found"),
        error.ContainerAlreadyRunning => return Response.notModified(),
        error.ContainerBeingRemoved => return Response.conflict("container is being removed"),
        else => return Response.internalError("start failed"),
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
        else => return Response.internalError("stop failed"),
    };

    return Response.noContent();
}

// DELETE /containers/{name}
pub fn remove(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = alloc;
    const name = req.params.get("name") orelse return Response.badRequest("missing name");
    const force = std.mem.eql(u8, req.query.get("force") orelse "false", "true");
    const remove_vols = std.mem.eql(u8, req.query.get("v") orelse "false", "true");

    remove_mod.containerRemove(daemon, name, force, remove_vols) catch |err| switch (err) {
        error.ContainerNotFound => return Response.notFound("container not found"),
        error.ContainerAlreadyRunning => return Response.conflict("stop the container first"),
        else => return Response.internalError("remove failed"),
    };

    return Response.noContent();
}

// GET /containers/json
pub fn list(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const all = std.mem.eql(u8, req.query.get("all") orelse "false", "true");

    const containers = daemon.containers.list(alloc) catch return Response.internalError("list failed");
    defer alloc.free(containers);

    var result = std.ArrayList(*Container).empty;
    defer result.deinit(alloc);

    for (containers) |ctr| {
        if (!all and !ctr.state.running) continue;
        result.append(alloc, ctr) catch return Response.internalError("out of memory");
    }

    const json = std.json.Stringify.valueAlloc(alloc, result.items, .{}) catch "[]";
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
    const content = daemon.containerLogs(name, alloc) catch |err| {
        return Response.fromError(err);
    };
    return Response.ok(content);
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

pub fn handleLogs(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    const container_id = req.params.get("id") orelse return Response.notFound("container not found");
    _ = container_id;

    var out_buf = std.ArrayList(u8).empty;
    defer out_buf.deinit(alloc);

    const stream = @import("../stream.zig");
    stream.MultiplexWriter.writeFrame(alloc, &out_buf, .stdout, "container stdout log entry\n") catch {};
    stream.MultiplexWriter.writeFrame(alloc, &out_buf, .stderr, "container stderr log entry\n") catch {};

    return Response{
        .status = .ok,
        .content_type = "application/vnd.docker.raw-stream",
        .body = try out_buf.toOwnedSlice(alloc),
    };
}

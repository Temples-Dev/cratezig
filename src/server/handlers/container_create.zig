//! POST /containers/create — decodes Docker's ContainerCreateConfig.
const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const types = @import("../../container/container.zig");
const PortBinding = types.PortBinding;
const RestartPolicy = types.RestartPolicy;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

const Strings = ?[]const []const u8;

/// Subset of the Engine API body we honour. Docker sends `null` for many
/// empty fields, so every list/object is optional.
const Body = struct {
    Image: ?[]const u8 = null,
    Cmd: Strings = null,
    Entrypoint: Strings = null,
    Env: Strings = null,
    WorkingDir: ?[]const u8 = null,
    User: ?[]const u8 = null,
    Tty: bool = false,
    OpenStdin: bool = false,
    StopSignal: ?[]const u8 = null,
    StopTimeout: ?u32 = null,
    Labels: ?std.json.Value = null,
    HostConfig: ?HostConfigBody = null,
};

const HostConfigBody = struct {
    Memory: i64 = 0,
    MemorySwap: i64 = 0,
    CpuShares: i64 = 0,
    CpuQuota: i64 = 0,
    CpuPeriod: i64 = 0,
    PidsLimit: ?i64 = null,
    PortBindings: ?std.json.Value = null,
    Binds: Strings = null,
    Mounts: ?std.json.Value = null,
    NetworkMode: ?[]const u8 = null,
    Dns: Strings = null,
    ExtraHosts: Strings = null,
    Privileged: bool = false,
    CapAdd: Strings = null,
    CapDrop: Strings = null,
    ReadonlyRootfs: bool = false,
    ShmSize: i64 = 0,
    Init: ?bool = null,
    RestartPolicy: ?struct { Name: []const u8 = "", MaximumRetryCount: u32 = 0 } = null,
    IpcMode: ?[]const u8 = null,
    PidMode: ?[]const u8 = null,
};

fn or_(v: Strings) []const []const u8 {
    return v orelse &.{};
}

pub fn create(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const parsed = std.json.parseFromSliceLeaky(Body, alloc, req.body, .{ .ignore_unknown_fields = true }) catch |err| {
        return Response.badRequest(std.fmt.allocPrint(alloc, "invalid container config: {}", .{err}) catch "invalid container config");
    };
    const image = parsed.Image orelse return Response.badRequest("config.Image is required");
    const hc: HostConfigBody = parsed.HostConfig orelse .{};

    const labels = stringMap(alloc, parsed.Labels) catch return Response.badRequest("invalid Labels");
    const ports = portBindings(alloc, hc.PortBindings) catch return Response.badRequest("invalid PortBindings");
    const binds = mergeMounts(alloc, or_(hc.Binds), hc.Mounts) catch |err| return Response.fromError(err);

    const resp = daemon.containerCreate(.{
        .config = .{
            .image = image,
            .cmd = or_(parsed.Cmd),
            .entrypoint = or_(parsed.Entrypoint),
            .env = or_(parsed.Env),
            .working_dir = parsed.WorkingDir orelse "",
            .user = parsed.User orelse "",
            .tty = parsed.Tty,
            .open_stdin = parsed.OpenStdin,
            .stop_signal = parsed.StopSignal orelse "SIGTERM",
            .stop_timeout = parsed.StopTimeout orelse 10,
            .labels = labels,
        },
        .host_config = .{
            .memory = hc.Memory,
            .memory_swap = hc.MemorySwap,
            .cpu_shares = hc.CpuShares,
            .cpu_quota = hc.CpuQuota,
            .cpu_period = hc.CpuPeriod,
            .pid_limits = hc.PidsLimit orelse 0,
            .port_bindings = ports,
            .binds = binds,
            .network_mode = hc.NetworkMode orelse "default",
            .dns = or_(hc.Dns),
            .extra_hosts = or_(hc.ExtraHosts),
            .privleged = hc.Privileged,
            .cap_add = or_(hc.CapAdd),
            .cap_drop = or_(hc.CapDrop),
            .read_only_rootfs = hc.ReadonlyRootfs,
            .shm_size = if (hc.ShmSize > 0) hc.ShmSize else 64 * 1024 * 1024,
            .init = hc.Init orelse false,
            .restart_policy = if (hc.RestartPolicy) |rp| .{ .name = RestartPolicy.parseName(rp.Name), .maximum_retry_count = rp.MaximumRetryCount } else .{},
            .ipc_mode = hc.IpcMode orelse "private",
            .pid_mode = hc.PidMode orelse "",
        },
        .name = req.query.get("name"),
    }) catch |err| return Response.fromError(err);

    const json = std.json.Stringify.valueAlloc(alloc, .{ .Id = resp.id[0..], .Warnings = resp.warnings }, .{}) catch
        return Response.internalError("out of memory");
    return Response.created(json);
}

fn stringMap(alloc: std.mem.Allocator, val: ?std.json.Value) !std.StringHashMap([]const u8) {
    var out = std.StringHashMap([]const u8).init(alloc);
    const obj = switch (val orelse return out) {
        .object => |o| o,
        .null => return out,
        else => return error.InvalidParameter,
    };
    var it = obj.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .string => |s| try out.put(e.key_ptr.*, s),
        else => return error.InvalidParameter,
    };
    return out;
}

/// {"80/tcp": [{"HostIp": "", "HostPort": "8080"}]}
fn portBindings(alloc: std.mem.Allocator, val: ?std.json.Value) !std.StringHashMap([]PortBinding) {
    var out = std.StringHashMap([]PortBinding).init(alloc);
    const obj = switch (val orelse return out) {
        .object => |o| o,
        .null => return out,
        else => return error.InvalidParameter,
    };
    var it = obj.iterator();
    while (it.next()) |e| {
        const arr = switch (e.value_ptr.*) {
            .array => |x| x.items,
            .null => &.{},
            else => return error.InvalidParameter,
        };
        const list = try alloc.alloc(PortBinding, arr.len);
        for (arr, 0..) |item, i| {
            const o = if (item == .object) item.object else return error.InvalidParameter;
            const ip = if (o.get("HostIp")) |v| (if (v == .string) v.string else "") else "";
            list[i] = .{
                .host_ip = if (ip.len > 0) ip else "0.0.0.0",
                .host_port = if (o.get("HostPort")) |v| (if (v == .string) v.string else "") else "",
            };
        }
        try out.put(e.key_ptr.*, list);
    }
    return out;
}

/// Folds `--mount type=bind` entries into Binds syntax. Volume and tmpfs
/// mounts arrive with Phase 5 and are rejected rather than silently dropped.
fn mergeMounts(alloc: std.mem.Allocator, binds: []const []const u8, mounts: ?std.json.Value) ![]const []const u8 {
    const arr = switch (mounts orelse return binds) {
        .array => |x| x.items,
        .null => return binds,
        else => return error.InvalidParameter,
    };
    var out = std.ArrayList([]const u8).empty;
    try out.appendSlice(alloc, binds);
    for (arr) |m| {
        const o = if (m == .object) m.object else return error.InvalidParameter;
        const typ = if (o.get("Type")) |v| (if (v == .string) v.string else "") else "";
        if (!std.mem.eql(u8, typ, "bind")) return error.NotImplemented;
        const src = if (o.get("Source")) |v| (if (v == .string) v.string else "") else "";
        const dst = if (o.get("Target")) |v| (if (v == .string) v.string else "") else "";
        const ro = if (o.get("ReadOnly")) |v| (v == .bool and v.bool) else false;
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{s}:{s}", .{ src, dst, if (ro) "ro" else "rw" }));
    }
    return out.toOwnedSlice(alloc);
}

test "create body tolerates Docker nulls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\{"Image":"alpine","Cmd":null,"Env":null,"Labels":{"k":"v"},
        \\ "HostConfig":{"Binds":null,"Mounts":[{"Type":"bind","Source":"/s","Target":"/t","ReadOnly":true}],
        \\ "RestartPolicy":{"Name":"on-failure","MaximumRetryCount":3},
        \\ "PortBindings":{"80/tcp":[{"HostIp":"","HostPort":"8080"}]}}}
    ;
    const p = try std.json.parseFromSliceLeaky(Body, a, body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(null, p.Cmd);
    const hc = p.HostConfig.?;
    try std.testing.expectEqual(RestartPolicy.Name.on_failure, RestartPolicy.parseName(hc.RestartPolicy.?.Name));
    const binds = try mergeMounts(a, or_(hc.Binds), hc.Mounts);
    try std.testing.expectEqualStrings("/s:/t:ro", binds[0]);
    const ports = try portBindings(a, hc.PortBindings);
    try std.testing.expectEqualStrings("0.0.0.0", ports.get("80/tcp").?[0].host_ip);
    try std.testing.expectEqualStrings("v", (try stringMap(a, p.Labels)).get("k").?);
}

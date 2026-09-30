//! Deep copies of container configuration into a container's own arena, so a
//! container never points at request-scoped or image-owned memory.
const std = @import("std");
const container = @import("container.zig");
const ContainerConfig = container.ContainerConfig;
const HostConfig = container.HostConfig;
const PortBinding = container.PortBinding;
const HealthCheckConfig = container.HealthCheckConfig;

pub fn strings(a: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, src.len);
    for (src, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
}

fn stringMap(a: std.mem.Allocator, src: std.StringHashMap([]const u8)) !std.StringHashMap([]const u8) {
    var out = std.StringHashMap([]const u8).init(a);
    var it = src.iterator();
    while (it.next()) |e| try out.put(try a.dupe(u8, e.key_ptr.*), try a.dupe(u8, e.value_ptr.*));
    return out;
}

fn portMap(a: std.mem.Allocator, src: std.StringHashMap([]PortBinding)) !std.StringHashMap([]PortBinding) {
    var out = std.StringHashMap([]PortBinding).init(a);
    var it = src.iterator();
    while (it.next()) |e| {
        const bindings = try a.alloc(PortBinding, e.value_ptr.len);
        for (e.value_ptr.*, 0..) |b, i| bindings[i] = .{
            .host_ip = try a.dupe(u8, b.host_ip),
            .host_port = try a.dupe(u8, b.host_port),
        };
        try out.put(try a.dupe(u8, e.key_ptr.*), bindings);
    }
    return out;
}

pub fn config(a: std.mem.Allocator, src: ContainerConfig) !ContainerConfig {
    var out = src;
    out.image = try a.dupe(u8, src.image);
    out.cmd = try strings(a, src.cmd);
    out.entrypoint = try strings(a, src.entrypoint);
    out.env = try strings(a, src.env);
    out.working_dir = try a.dupe(u8, src.working_dir);
    out.user = try a.dupe(u8, src.user);
    out.stop_signal = try a.dupe(u8, src.stop_signal);
    out.labels = try stringMap(a, src.labels);
    if (src.healthcheck) |hc| {
        out.healthcheck = HealthCheckConfig{
            .health_test = try strings(a, hc.health_test),
            .interval = hc.interval,
            .timeout = hc.timeout,
            .retries = hc.retries,
            .start_period = hc.start_period,
        };
    }
    return out;
}

pub fn hostConfig(a: std.mem.Allocator, src: HostConfig) !HostConfig {
    var out = src;
    out.port_bindings = try portMap(a, src.port_bindings);
    out.binds = try strings(a, src.binds);
    out.mounts = try strings(a, src.mounts);
    out.network_mode = try a.dupe(u8, src.network_mode);
    out.dns = try strings(a, src.dns);
    out.extra_hosts = try strings(a, src.extra_hosts);
    out.cap_add = try strings(a, src.cap_add);
    out.cap_drop = try strings(a, src.cap_drop);
    out.ipc_mode = try a.dupe(u8, src.ipc_mode);
    out.pid_mode = try a.dupe(u8, src.pid_mode);
    return out;
}

test "config clone survives source arena teardown" {
    const gpa = std.testing.allocator;
    var dst = std.heap.ArenaAllocator.init(gpa);
    defer dst.deinit();

    var src_arena = std.heap.ArenaAllocator.init(gpa);
    const sa = src_arena.allocator();
    var labels = std.StringHashMap([]const u8).init(sa);
    try labels.put(try sa.dupe(u8, "k"), try sa.dupe(u8, "v"));
    const src = ContainerConfig{
        .image = try sa.dupe(u8, "alpine"),
        .cmd = try strings(sa, &.{ "echo", "hi" }),
        .labels = labels,
    };

    const copy = try config(dst.allocator(), src);
    src_arena.deinit();

    try std.testing.expectEqualStrings("alpine", copy.image);
    try std.testing.expectEqualStrings("hi", copy.cmd[1]);
    try std.testing.expectEqualStrings("v", copy.labels.get("k").?);
}

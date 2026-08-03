const std = @import("std");

const BRIDGE_NAME = "docker0";
const BRIDGE_IP = "172.17.0.1";
const SUBNET = "172.17.0.0/16";
const SUBNET_MASK = "172.17.0.1/16";

/// Create the docker0 bridge on daemon startup.
pub fn setupBridge(io: std.Io) !void {
    // Delete existing bridge if it exists, to avoid errors
    runCmd(io, std.heap.page_allocator, &.{ "ip", "link", "del", BRIDGE_NAME }) catch {};

    try ip(io, &.{ "link", "add", BRIDGE_NAME, "type", "bridge" });
    try ip(io, &.{ "addr", "add", SUBNET_MASK, "dev", BRIDGE_NAME });
    try ip(io, &.{ "link", "set", BRIDGE_NAME, "up" });

    // Enable IP forwarding
    try writeFile(io, "/proc/sys/net/ipv4/ip_forward", "1");

    // iptables: masquerade container traffic going out to the internet
    // Delete first to avoid duplicates, then add
    runCmd(io, std.heap.page_allocator, &.{ "iptables", "-t", "nat", "-D", "POSTROUTING", "-s", SUBNET, "!", "-o", BRIDGE_NAME, "-j", "MASQUERADE" }) catch {};
    try iptables(io, &.{
        "-t", "nat", "-A", "POSTROUTING",
        "-s", SUBNET,
        "!", "-o", BRIDGE_NAME,
        "-j", "MASQUERADE",
    });
}

/// Connect a container to the bridge.
pub fn connectContainer(io: std.Io, container_id: []const u8, container_pid: u32, assigned_ip: []const u8) !void {
    var veth_buf: [32]u8 = undefined;
    const veth_host = vethName(container_id, &veth_buf);

    // Create veth pair: {veth_host} on host, eth0 in container
    try ip(io, &.{ "link", "add", veth_host, "type", "veth", "peer", "name", "eth0" });

    // Attach host end to bridge
    try ip(io, &.{ "link", "set", veth_host, "master", BRIDGE_NAME });
    try ip(io, &.{ "link", "set", veth_host, "up" });

    // Move container end (eth0) into the container's network namespace
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{container_pid}) catch unreachable;
    try ip(io, &.{ "link", "set", "eth0", "netns", pid_str });

    // Configure networking inside the container namespace
    var ip_cidr_buf: [32]u8 = undefined;
    const ip_cidr = std.fmt.bufPrint(&ip_cidr_buf, "{s}/16", .{assigned_ip}) catch unreachable;
    var nsenter_buf: [64]u8 = undefined;
    const netns_path = std.fmt.bufPrint(&nsenter_buf, "/proc/{d}/ns/net", .{container_pid}) catch unreachable;
    try nsenter(io, netns_path, &.{ "ip", "addr", "add", ip_cidr, "dev", "eth0" });
    try nsenter(io, netns_path, &.{ "ip", "link", "set", "eth0", "up" });
    try nsenter(io, netns_path, &.{ "ip", "lo", "up" });
    try nsenter(io, netns_path, &.{ "ip", "route", "add", "default", "via", BRIDGE_IP });
}

/// Remove a container's veth pair. Called when container stops.
pub fn disconnectContainer(io: std.Io, container_id: []const u8) !void {
    var veth_buf: [32]u8 = undefined;
    const veth_host = vethName(container_id, &veth_buf);
    ip(io, &.{ "link", "del", veth_host }) catch {}; // ignore errors (might already be gone)
}

/// Add an iptables DNAT rule for a port mapping.
pub fn addPortMapping(io: std.Io, host_port: u16, container_ip: []const u8, container_port: u16, proto: []const u8) !void {
    var dest_buf: [64]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}:{d}", .{ container_ip, container_port }) catch unreachable;
    var dport_buf: [8]u8 = undefined;
    const dport = std.fmt.bufPrint(&dport_buf, "{d}", .{host_port}) catch unreachable;

    try iptables(io, &.{
        "-t", "nat", "-A", "DOCKER",
        "!", "-i", BRIDGE_NAME,
        "-p", proto, "--dport", dport,
        "-j", "DNAT", "--to-destination", dest,
    });
}

fn vethName(container_id: []const u8, buf: *[32]u8) []u8 {
    return std.fmt.bufPrint(buf, "veth{s}", .{container_id[0..8]}) catch unreachable;
}

fn ip(io: std.Io, args: []const []const u8) !void {
    var full_args = std.ArrayList([]const u8).empty;
    defer full_args.deinit(std.heap.page_allocator);
    try full_args.append(std.heap.page_allocator, "ip");
    try full_args.appendSlice(std.heap.page_allocator, args);

    try runCmd(io, std.heap.page_allocator, full_args.items);
}

fn iptables(io: std.Io, args: []const []const u8) !void {
    var full_args = std.ArrayList([]const u8).empty;
    defer full_args.deinit(std.heap.page_allocator);
    try full_args.append(std.heap.page_allocator, "iptables");
    try full_args.appendSlice(std.heap.page_allocator, args);

    try runCmd(io, std.heap.page_allocator, full_args.items);
}

fn nsenter(io: std.Io, netns_path: []const u8, cmd: []const []const u8) !void {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(std.heap.page_allocator);
    var ns_arg_buf: [128]u8 = undefined;
    const ns_arg = std.fmt.bufPrint(&ns_arg_buf, "--net={s}", .{netns_path}) catch unreachable;
    try args.appendSlice(std.heap.page_allocator, &.{ "nsenter", ns_arg, "--" });
    try args.appendSlice(std.heap.page_allocator, cmd);

    try runCmd(io, std.heap.page_allocator, args.items);
}

fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .write_only });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn runCmd(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var proc = try std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    
    var stdout_reader = proc.stdout.?.reader(io, &stdout_buf);
    var stderr_reader = proc.stderr.?.reader(io, &stderr_buf);
    
    const stdout_bytes = try stdout_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(4096));
    defer allocator.free(stdout_bytes);
    
    const stderr_bytes = try stderr_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(4096));
    defer allocator.free(stderr_bytes);

    const term = try proc.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.log.err("command failed: {s}", .{stderr_bytes});
                return error.NetworkError;
            }
        },
        else => return error.NetworkError,
    }
}

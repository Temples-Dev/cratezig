const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const Container = @import("../container/container.zig").Container;

const DEFAULT_CAPS = [_][]const u8{
    "CAP_CHOWN",
    "CAP_DAC_OVERRIDE",
    "CAP_FSETID",
    "CAP_FOWNER",
    "CAP_MKNOD",
    "CAP_NET_RAW",
    "CAP_SETGID",
    "CAP_SETUID",
    "CAP_SETFCAP",
    "CAP_SETPCAP",
    "CAP_NET_BIND_SERVICE",
    "CAP_SYS_CHROOT",
    "CAP_KILL",
    "CAP_AUDIT_WRITE",
};

const Mount = struct {
    dest: []const u8,
    source: []const u8,
    mount_type: []const u8,
    opts: []const []const u8,
};

const STANDARD_MOUNTS = [_]Mount{
    .{ .dest = "/proc", .source = "proc", .mount_type = "proc", .opts = &.{"nosuid", "noexec", "nodev"} },
    .{ .dest = "/dev", .source = "tmpfs", .mount_type = "tmpfs", .opts = &.{"nosuid", "strictatime", "mode=755", "size=65536k"} },
    .{ .dest = "/dev/pts", .source = "devpts", .mount_type = "devpts", .opts = &.{"nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620", "gid=5"} },
    .{ .dest = "/dev/mqueue", .source = "mqueue", .mount_type = "mqueue", .opts = &.{"nosuid", "noexec", "nodev"} },
    .{ .dest = "/sys", .source = "sysfs", .mount_type = "sysfs", .opts = &.{"nosuid", "noexec", "nodev", "ro"} },
    .{ .dest = "/sys/fs/cgroup", .source = "cgroup", .mount_type = "cgroup2", .opts = &.{"nosuid", "noexec", "nodev", "relatime", "ro"} },
};

pub fn generate(ctr: *const Container, buf: []u8, daemon: *Daemon) ![]const u8 {
    _ = daemon;
    var writer = std.Io.Writer.fixed(buf);

    try writer.writeAll("{");

    // ociVersion
    try writer.writeAll("\"ociVersion\":\"1.1.0\",");

    // process
    try writer.writeAll("\"process\":{");

    // Args
    try writer.writeAll("\"args\":");
    try writeArgs(&writer, ctr.config.entrypoint, ctr.config.cmd);
    try writer.writeByte(',');

    // Env
    try writer.writeAll("\"env\":");
    try writeStringArray(&writer, ctr.config.env);
    try writer.writeByte(',');

    // WorkingDir
    try writer.print("\"cwd\":\"{s}\",", .{
        if (ctr.config.working_dir.len > 0) ctr.config.working_dir else "/",
    });

    // Terminal
    try writer.print("\"terminal\":{},", .{ctr.config.tty});

    // User
    try writer.writeAll("\"user\":{\"uid\":0,\"gid\":0},");

    // Capabilities
    try writer.writeAll("\"capabilities\":{");
    const caps = if (ctr.host_config.privleged) "\"all\"" else try buildCapsList(ctr, buf);
    for ([_][]const u8{ "bounding", "effective", "permitted", "ambient" }) |set| {
        try writer.print("\"{s}\":{s},", .{ set, caps });
    }
    writer.end -= 1; // Overwrite trailing comma
    try writer.writeAll("},");

    // rlimits
    try writer.writeAll("\"rlimits\":[{\"type\":\"RLIMIT_NOFILE\",\"hard\":1048576,\"soft\":1048576}]");
    try writer.writeAll("},"); // close process

    // root
    try writer.print("\"root\":{{\"path\":\"{s}\",\"readonly\":{}}},", .{ ctr.rootfs_paths, ctr.host_config.read_only_rootfs });

    // hostname
    try writer.print("\"hostname\":\"{s}\",", .{ctr.id_short[0..]});

    // mounts
    try writer.writeAll("\"mounts\":[");
    for (STANDARD_MOUNTS, 0..) |m, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"destination\":\"{s}\",\"type\":\"{s}\",\"source\":\"{s}\",\"options\":[", .{ m.dest, m.mount_type, m.source });
        for (m.opts, 0..) |opt, j| {
            if (j > 0) try writer.writeByte(',');
            try writer.print("\"{s}\"", .{opt});
        }
        try writer.writeAll("]}");
    }
    for (ctr.host_config.binds) |bind| {
        try writeBind(&writer, bind);
    }
    try writer.writeAll("],");

    // linux
    try writer.writeAll("\"linux\":{");

    // namespaces
    try writer.writeAll("\"namespaces\":[");
    try writer.writeAll("{\"type\":\"pid\"},");
    try writer.writeAll("{\"type\":\"ipc\"},");
    try writer.writeAll("{\"type\":\"uts\"},");
    try writer.writeAll("{\"type\":\"mount\"}");

    const net_mode = ctr.host_config.network_mode;
    if (!std.mem.eql(u8, net_mode, "host")) {
        var netns_buf: [128]u8 = undefined;
        const netns_path = std.fmt.bufPrint(&netns_buf, "/var/run/docker/netns/{s}", .{ctr.id[0..]}) catch unreachable;
        try writer.print(",{{\"type\":\"network\",\"path\":\"{s}\"}}", .{netns_path});
    }
    try writer.writeAll("],");

    // cgroupsPath
    try writer.print("\"cgroupsPath\":\"/docker/{s}\",", .{ctr.id[0..]});

    // resources
    try writer.writeAll("\"resources\":{");
    if (ctr.host_config.memory > 0) {
        try writer.print("\"memory\":{{\"limit\":{d}}},", .{ctr.host_config.memory});
    }
    if (ctr.host_config.cpu_shares > 0) {
        try writer.print("\"cpu\":{{\"shares\":{d}}},", .{ctr.host_config.cpu_shares});
    }
    if (ctr.host_config.pid_limits > 0) {
        try writer.print("\"pids\":{{\"limit\":{d}}}", .{ctr.host_config.pid_limits});
    } else {
        try writer.writeAll("\"pids\":{\"limit\":1024}");
    }
    try writer.writeAll("},");

    // sysctl
    try writer.writeAll("\"sysctl\":{},");

    // AppArmor Profile
    try writer.writeAll("\"appArmorProfile\":\"docker-default\"");

    try writer.writeAll("}}");

    return buf[0..(buf.len - writer.unusedCapacityLen())];
}

fn writeArgs(writer: anytype, entrypoint: []const []const u8, cmd: []const []const u8) !void {
    try writer.writeByte('[');
    var first = true;
    for (entrypoint) |arg| {
        if (!first) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{arg});
        first = false;
    }
    for (cmd) |arg| {
        if (!first) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{arg});
        first = false;
    }
    try writer.writeByte(']');
}

fn writeStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{item});
    }
    try writer.writeByte(']');
}

fn writeBind(writer: anytype, bind: []const u8) !void {
    var parts = std.mem.splitScalar(u8, bind, ':');
    const host = parts.next() orelse return;
    const dest = parts.next() orelse return;
    const mode = parts.next() orelse "rw";
    try writer.print(",{{\"destination\":\"{s}\",\"type\":\"bind\",\"source\":\"{s}\",\"options\":[\"rbind\",\"{s}\"]}}", .{ dest, host, mode });
}

fn buildCapsList(ctr: *const Container, buf: []u8) ![]u8 {
    _ = ctr;
    _ = buf;
    return @constCast("[\"CAP_CHOWN\",\"CAP_DAC_OVERRIDE\",\"CAP_FSETID\",\"CAP_FOWNER\",\"CAP_MKNOD\",\"CAP_NET_RAW\",\"CAP_SETGID\",\"CAP_SETUID\",\"CAP_SETFCAP\",\"CAP_SETPCAP\",\"CAP_NET_BIND_SERVICE\",\"CAP_SYS_CHROOT\",\"CAP_KILL\",\"CAP_AUDIT_WRITE\"]");
}

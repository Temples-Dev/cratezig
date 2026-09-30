//! Builds the OCI runtime spec (config.json) for a container.
const std = @import("std");
const Container = @import("../container/container.zig").Container;
const HostConfig = @import("../container/container.zig").HostConfig;
const seccomp = @import("../vpm/seccomp.zig");
const user = @import("../runtime/user.zig");
const CrateError = @import("../errdefs/errors.zig").Error;

/// Docker's default capability set.
const default_caps = [_][]const u8{
    "CAP_CHOWN",   "CAP_DAC_OVERRIDE", "CAP_FSETID",           "CAP_FOWNER",     "CAP_MKNOD",
    "CAP_NET_RAW", "CAP_SETGID",       "CAP_SETUID",           "CAP_SETFCAP",    "CAP_SETPCAP",
    "CAP_KILL",    "CAP_AUDIT_WRITE",  "CAP_NET_BIND_SERVICE", "CAP_SYS_CHROOT",
};

const all_caps = default_caps ++ [_][]const u8{
    "CAP_DAC_READ_SEARCH", "CAP_LINUX_IMMUTABLE", "CAP_NET_BROADCAST",  "CAP_NET_ADMIN",   "CAP_IPC_LOCK",
    "CAP_IPC_OWNER",       "CAP_SYS_MODULE",      "CAP_SYS_RAWIO",      "CAP_SYS_PTRACE",  "CAP_SYS_PACCT",
    "CAP_SYS_ADMIN",       "CAP_SYS_BOOT",        "CAP_SYS_NICE",       "CAP_SYS_RESOURCE", "CAP_SYS_TIME",
    "CAP_SYS_TTY_CONFIG",  "CAP_LEASE",           "CAP_AUDIT_CONTROL",  "CAP_MAC_OVERRIDE", "CAP_MAC_ADMIN",
    "CAP_SYSLOG",          "CAP_WAKE_ALARM",      "CAP_BLOCK_SUSPEND",  "CAP_AUDIT_READ",  "CAP_PERFMON",
    "CAP_BPF",             "CAP_CHECKPOINT_RESTORE",
};

const masked_paths = [_][]const u8{
    "/proc/asound", "/proc/acpi",        "/proc/kcore",       "/proc/keys",    "/proc/latency_stats",
    "/proc/timer_list", "/proc/timer_stats", "/proc/sched_debug", "/proc/scsi", "/sys/firmware",
    "/sys/devices/virtual/powercap",
};
const readonly_paths = [_][]const u8{ "/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys", "/proc/sysrq-trigger" };

const Mount = struct { destination: []const u8, type: []const u8, source: []const u8, options: []const []const u8 };

const standard_mounts = [_]Mount{
    .{ .destination = "/proc", .type = "proc", .source = "proc", .options = &.{ "nosuid", "noexec", "nodev" } },
    .{ .destination = "/dev", .type = "tmpfs", .source = "tmpfs", .options = &.{ "nosuid", "strictatime", "mode=755", "size=65536k" } },
    .{ .destination = "/dev/pts", .type = "devpts", .source = "devpts", .options = &.{ "nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620", "gid=5" } },
    .{ .destination = "/dev/mqueue", .type = "mqueue", .source = "mqueue", .options = &.{ "nosuid", "noexec", "nodev" } },
    .{ .destination = "/sys", .type = "sysfs", .source = "sysfs", .options = &.{ "nosuid", "noexec", "nodev", "ro" } },
    .{ .destination = "/sys/fs/cgroup", .type = "cgroup", .source = "cgroup", .options = &.{ "nosuid", "noexec", "nodev", "relatime", "ro" } },
};

/// Renders the spec into `buf`. `ctr.rootfs_paths` must already be mounted
/// (user names are resolved against its /etc/passwd). `scratch` backs
/// temporary allocations.
pub fn generate(ctr: *const Container, io: std.Io, scratch: std.mem.Allocator, buf: []u8) ![]const u8 {
    const hc = ctr.host_config;
    if (ctr.config.entrypoint.len + ctr.config.cmd.len == 0) return CrateError.NoCommandSpecified;

    var arena = std.heap.ArenaAllocator.init(scratch);
    defer arena.deinit();
    const a = arena.allocator();

    const ids = user.resolve(io, a, ctr.rootfs_paths, ctr.config.user) catch |err| {
        std.log.err("cannot resolve user '{s}': {}", .{ ctr.config.user, err });
        return CrateError.InvalidParameter;
    };
    const caps = try effectiveCaps(a, hc);
    const args = try std.mem.concat(a, []const u8, &.{ ctr.config.entrypoint, ctr.config.cmd });
    const shm_opt = try std.fmt.allocPrint(a, "size={d}", .{if (hc.shm_size > 0) hc.shm_size else 64 * 1024 * 1024});

    var w = std.Io.Writer.fixed(buf);
    var jws: std.json.Stringify = .{ .writer = &w };
    try jws.beginObject();
    try field(&jws, "ociVersion", "1.1.0");

    try jws.objectField("process");
    try jws.beginObject();
    // TTY needs a console socket (Phase 3); until then output goes to the log file.
    try field(&jws, "terminal", false);
    try jws.objectField("user");
    try jws.write(.{ .uid = ids.uid, .gid = ids.gid });
    try field(&jws, "args", args);
    try field(&jws, "env", ctr.config.env);
    try field(&jws, "cwd", if (ctr.config.working_dir.len > 0) ctr.config.working_dir else "/");
    try jws.objectField("capabilities");
    try jws.write(.{ .bounding = caps, .effective = caps, .permitted = caps });
    try jws.objectField("rlimits");
    try jws.write(&[_]struct { type: []const u8, hard: u64, soft: u64 }{.{ .type = "RLIMIT_NOFILE", .hard = 1048576, .soft = 1048576 }});
    try field(&jws, "noNewPrivileges", !hc.privleged);
    try jws.endObject();

    try jws.objectField("root");
    try jws.write(.{ .path = ctr.rootfs_paths, .readonly = hc.read_only_rootfs });
    try field(&jws, "hostname", ctr.id_short[0..]);

    try jws.objectField("mounts");
    try jws.beginArray();
    for (standard_mounts) |m| try jws.write(m);
    try jws.write(Mount{ .destination = "/dev/shm", .type = "tmpfs", .source = "shm", .options = &.{ "nosuid", "noexec", "nodev", "mode=1777", shm_opt } });
    for (hc.binds) |bind| {
        const m = try parseBind(a, bind) orelse {
            std.log.warn("skipping unsupported bind '{s}'", .{bind});
            continue;
        };
        try jws.write(m);
    }
    try jws.endArray();

    try jws.objectField("linux");
    try jws.beginObject();
    try jws.objectField("namespaces");
    try jws.beginArray();
    for ([_][]const u8{ "pid", "ipc", "uts", "mount" }) |ns| try jws.write(.{ .type = ns });
    // A fresh, empty netns (loopback only) until bridge networking lands.
    if (!std.mem.eql(u8, hc.network_mode, "host")) try jws.write(.{ .type = "network" });
    try jws.endArray();
    try field(&jws, "cgroupsPath", try std.fmt.allocPrint(a, "/cratezig/{s}", .{ctr.id[0..]}));
    try jws.objectField("resources");
    try writeResources(&jws, hc);
    if (!hc.privleged) {
        try field(&jws, "maskedPaths", &masked_paths);
        try field(&jws, "readonlyPaths", &readonly_paths);
        try jws.objectField("seccomp");
        try seccomp.writeProfile(&jws, caps);
    }
    try jws.endObject();

    try jws.endObject();
    return w.buffered();
}

fn field(jws: *std.json.Stringify, name: []const u8, v: anytype) !void {
    try jws.objectField(name);
    try jws.write(v);
}

fn writeResources(jws: *std.json.Stringify, hc: HostConfig) !void {
    try jws.beginObject();
    if (hc.memory > 0) {
        try jws.objectField("memory");
        try jws.beginObject();
        try field(jws, "limit", hc.memory);
        if (hc.memory_swap != 0) try field(jws, "swap", hc.memory_swap);
        try jws.endObject();
    }
    if (hc.cpu_shares > 0 or hc.cpu_quota > 0) {
        try jws.objectField("cpu");
        try jws.beginObject();
        if (hc.cpu_shares > 0) try field(jws, "shares", hc.cpu_shares);
        if (hc.cpu_quota > 0) {
            try field(jws, "quota", hc.cpu_quota);
            try field(jws, "period", if (hc.cpu_period > 0) hc.cpu_period else 100_000);
        }
        try jws.endObject();
    }
    try jws.objectField("pids");
    try jws.write(.{ .limit = if (hc.pid_limits > 0) hc.pid_limits else @as(i64, -1) });
    try jws.endObject();
}

/// Default caps, plus CapAdd, minus CapDrop. "ALL" and names without the
/// CAP_ prefix are accepted, as in Docker.
fn effectiveCaps(a: std.mem.Allocator, hc: HostConfig) ![]const []const u8 {
    if (hc.privleged) return &all_caps;
    var set = std.ArrayList([]const u8).empty;
    try set.appendSlice(a, &default_caps);
    for (hc.cap_drop) |raw| {
        const c = try normalizeCap(a, raw);
        if (std.mem.eql(u8, c, "CAP_ALL")) {
            set.clearRetainingCapacity();
        } else if (indexOf(set.items, c)) |i| {
            _ = set.orderedRemove(i);
        }
    }
    for (hc.cap_add) |raw| {
        const c = try normalizeCap(a, raw);
        const adds: []const []const u8 = if (std.mem.eql(u8, c, "CAP_ALL")) &all_caps else &.{c};
        for (adds) |x| if (indexOf(set.items, x) == null) try set.append(a, x);
    }
    return set.items;
}

fn indexOf(items: []const []const u8, needle: []const u8) ?usize {
    for (items, 0..) |x, i| if (std.mem.eql(u8, x, needle)) return i;
    return null;
}

fn normalizeCap(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const upper = try std.ascii.allocUpperString(a, raw);
    return if (std.mem.startsWith(u8, upper, "CAP_")) upper else std.fmt.allocPrint(a, "CAP_{s}", .{upper});
}

/// "host:container[:opts]" → bind mount. Named volumes are resolved by the
/// volume service in Phase 5; entries without an absolute host path are skipped.
fn parseBind(a: std.mem.Allocator, bind: []const u8) !?Mount {
    var parts = std.mem.splitScalar(u8, bind, ':');
    const host = parts.next() orelse return null;
    const dest = parts.next() orelse return null;
    if (host.len == 0 or host[0] != '/' or dest.len == 0 or dest[0] != '/') return null;
    var opts = std.ArrayList([]const u8).empty;
    try opts.appendSlice(a, &.{ "rbind", "rprivate" });
    var ro = false;
    if (parts.next()) |mode_list| {
        var modes = std.mem.splitScalar(u8, mode_list, ',');
        while (modes.next()) |m| if (std.mem.eql(u8, m, "ro")) {
            ro = true;
        };
    }
    try opts.append(a, if (ro) "ro" else "rw");
    return .{ .destination = dest, .type = "bind", .source = host, .options = try opts.toOwnedSlice(a) };
}

test "effectiveCaps applies add/drop and ALL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const caps = try effectiveCaps(a, .{ .port_bindings = undefined, .cap_add = &.{"net_admin"}, .cap_drop = &.{"CAP_CHOWN"} });
    var has_admin = false;
    for (caps) |c| {
        try std.testing.expect(!std.mem.eql(u8, c, "CAP_CHOWN"));
        if (std.mem.eql(u8, c, "CAP_NET_ADMIN")) has_admin = true;
    }
    try std.testing.expect(has_admin);
    const none = try effectiveCaps(a, .{ .port_bindings = undefined, .cap_drop = &.{"ALL"} });
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "parseBind handles ro and rejects relative sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = (try parseBind(arena.allocator(), "/src:/app:ro")).?;
    try std.testing.expectEqualStrings("ro", m.options[2]);
    try std.testing.expectEqual(null, try parseBind(arena.allocator(), "vol:/data"));
}

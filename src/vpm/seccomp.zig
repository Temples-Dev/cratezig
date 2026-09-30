//! Seccomp profile modelled on Docker's default: everything is allowed except
//! syscalls that escape or administer the host. A group is re-allowed when
//! the container holds the capability that already gates it in the kernel.
const std = @import("std");

pub const DenyGroup = struct {
    /// Capability that lifts this group (null = always denied).
    cap: ?[]const u8,
    names: []const []const u8,
};

pub const deny_groups = [_]DenyGroup{
    .{ .cap = null, .names = &.{ "acct", "add_key", "keyctl", "request_key", "bpf", "perf_event_open", "userfaultfd", "lookup_dcookie", "kexec_load", "kexec_file_load", "create_module", "get_kernel_syms", "query_module", "nfsservctl", "uselib", "ustat", "sysfs", "_sysctl", "vm86", "vm86old", "swapon", "swapoff", "get_mempolicy", "set_mempolicy", "mbind", "move_pages" } },
    .{ .cap = "CAP_SYS_ADMIN", .names = &.{ "mount", "umount", "umount2", "unshare", "setns", "pivot_root", "quotactl", "fsopen", "fsmount", "fsconfig", "move_mount", "open_tree" } },
    .{ .cap = "CAP_DAC_READ_SEARCH", .names = &.{ "open_by_handle_at", "name_to_handle_at" } },
    .{ .cap = "CAP_SYS_PTRACE", .names = &.{ "ptrace", "process_vm_readv", "process_vm_writev", "kcmp" } },
    .{ .cap = "CAP_SYS_TIME", .names = &.{ "settimeofday", "stime", "clock_settime", "clock_adjtime" } },
    .{ .cap = "CAP_SYS_MODULE", .names = &.{ "init_module", "finit_module", "delete_module" } },
    .{ .cap = "CAP_SYS_BOOT", .names = &.{"reboot"} },
    .{ .cap = "CAP_SYS_RAWIO", .names = &.{ "ioperm", "iopl" } },
};

fn hasCap(caps: []const []const u8, cap: []const u8) bool {
    for (caps) |c| if (std.mem.eql(u8, c, cap)) return true;
    return false;
}

/// Writes the `seccomp` object for an OCI spec. `caps` is the container's
/// effective capability set.
pub fn writeProfile(jws: anytype, caps: []const []const u8) !void {
    try jws.beginObject();
    try jws.objectField("defaultAction");
    try jws.write("SCMP_ACT_ALLOW");
    try jws.objectField("architectures");
    try jws.write(&[_][]const u8{ "SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32", "SCMP_ARCH_AARCH64", "SCMP_ARCH_ARM" });
    try jws.objectField("syscalls");
    try jws.beginArray();
    for (deny_groups) |g| {
        if (g.cap) |cap| if (hasCap(caps, cap)) continue;
        try jws.beginObject();
        try jws.objectField("names");
        try jws.write(g.names);
        try jws.objectField("action");
        try jws.write("SCMP_ACT_ERRNO");
        try jws.objectField("errnoRet");
        try jws.write(1); // EPERM
        try jws.endObject();
    }
    try jws.endArray();
    try jws.endObject();
}

test "capabilities lift their deny group" {
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var jws: std.json.Stringify = .{ .writer = &w };
    try writeProfile(&jws, &.{"CAP_SYS_PTRACE"});
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"mount\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ptrace\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SCMP_ACT_ALLOW") != null);
}

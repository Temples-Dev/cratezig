const std = @import("std");
const PrivilegeLevel = @import("../runtime/privilege.zig").PrivilegeLevel;

pub const SeccompAction = []const u8;

pub const SyscallRule = struct {
    names: []const []const u8,
    action: SeccompAction = "SCMP_ACT_ALLOW",
};

pub const SeccompProfile = struct {
    default_action: SeccompAction = "SCMP_ACT_ERRNO",
    architectures: []const []const u8 = &.{"SCMP_ARCH_X86_64", "SCMP_ARCH_AARCH64"},
    syscalls: []const SyscallRule,

    pub fn deinit(self: *SeccompProfile, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
    }
};

pub const SeccompGenerator = struct {
    pub fn generateDefaultProfile(level: PrivilegeLevel) SeccompProfile {
        if (level == .privileged) {
            return .{
                .default_action = "SCMP_ACT_ALLOW",
                .syscalls = &.{},
            };
        }

        const restricted_syscalls = [_]SyscallRule{
            .{
                .names = &.{
                    "read", "write", "open", "openat", "close", "stat", "fstat", "lstat",
                    "poll", "lseek", "mmap", "mprotect", "munmap", "brk", "rt_sigaction",
                    "rt_sigprocmask", "ioctl", "access", "pipe", "select", "sched_yield",
                    "dup", "dup2", "getpid", "getuid", "getgid", "geteuid", "getegid",
                    "socket", "connect", "accept", "sendto", "recvfrom", "bind", "listen",
                    "clone", "execve", "exit", "exit_group", "wait4", "futex", "epoll_create1",
                    "epoll_ctl", "epoll_wait", "fcntl", "getdents64",
                },
                .action = "SCMP_ACT_ALLOW",
            },
        };

        return .{
            .default_action = "SCMP_ACT_ERRNO",
            .syscalls = &restricted_syscalls,
        };
    }
};

test "seccomp profile generation per privilege level" {
    const default_profile = SeccompGenerator.generateDefaultProfile(.standard);
    try std.testing.expectEqualStrings("SCMP_ACT_ERRNO", default_profile.default_action);
    try std.testing.expect(default_profile.syscalls.len > 0);

    const privileged_profile = SeccompGenerator.generateDefaultProfile(.privileged);
    try std.testing.expectEqualStrings("SCMP_ACT_ALLOW", privileged_profile.default_action);
}

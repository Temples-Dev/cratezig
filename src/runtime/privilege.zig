const std = @import("std");

pub const PrivilegeLevel = enum {
    rootless,
    restricted,
    standard,
    privileged,
};

pub const Capability = enum {
    cap_chown,
    cap_dac_override,
    cap_dac_read_search,
    cap_fowner,
    cap_fsetid,
    cap_kill,
    cap_setgid,
    cap_setuid,
    cap_setpcap,
    cap_net_bind_service,
    cap_net_raw,
    cap_sys_chroot,
    cap_mknod,
    cap_audit_write,
    cap_setfcap,
    cap_sys_admin,
    cap_sys_ptrace,
    cap_sys_rawio,
    cap_sys_module,

    pub fn toString(self: Capability) []const u8 {
        return switch (self) {
            .cap_chown => "CAP_CHOWN",
            .cap_dac_override => "CAP_DAC_OVERRIDE",
            .cap_dac_read_search => "CAP_DAC_READ_SEARCH",
            .cap_fowner => "CAP_FOWNER",
            .cap_fsetid => "CAP_FSETID",
            .cap_kill => "CAP_KILL",
            .cap_setgid => "CAP_SETGID",
            .cap_setuid => "CAP_SETUID",
            .cap_setpcap => "CAP_SETPCAP",
            .cap_net_bind_service => "CAP_NET_BIND_SERVICE",
            .cap_net_raw => "CAP_NET_RAW",
            .cap_sys_chroot => "CAP_SYS_CHROOT",
            .cap_mknod => "CAP_MKNOD",
            .cap_audit_write => "CAP_AUDIT_WRITE",
            .cap_setfcap => "CAP_SETFCAP",
            .cap_sys_admin => "CAP_SYS_ADMIN",
            .cap_sys_ptrace => "CAP_SYS_PTRACE",
            .cap_sys_rawio => "CAP_SYS_RAWIO",
            .cap_sys_module => "CAP_SYS_MODULE",
        };
    }
};

pub const IdMap = struct {
    container_id: u32,
    host_id: u32,
    size: u32,
};

pub const CapabilitySet = struct {
    capabilities: std.ArrayList(Capability),

    pub fn init(allocator: std.mem.Allocator) CapabilitySet {
        _ = allocator;
        return .{
            .capabilities = std.ArrayList(Capability).empty,
        };
    }

    pub fn deinit(self: *CapabilitySet, allocator: std.mem.Allocator) void {
        self.capabilities.deinit(allocator);
    }

    pub fn initDefault(allocator: std.mem.Allocator, level: PrivilegeLevel) !CapabilitySet {
        var set = CapabilitySet.init(allocator);
        errdefer set.deinit(allocator);

        switch (level) {
            .restricted => {
                try set.capabilities.append(allocator, .cap_chown);
                try set.capabilities.append(allocator, .cap_net_bind_service);
            },
            .rootless, .standard => {
                const std_caps = [_]Capability{
                    .cap_chown,
                    .cap_dac_override,
                    .cap_fowner,
                    .cap_fsetid,
                    .cap_kill,
                    .cap_setgid,
                    .cap_setuid,
                    .cap_setpcap,
                    .cap_net_bind_service,
                    .cap_net_raw,
                    .cap_sys_chroot,
                    .cap_mknod,
                    .cap_audit_write,
                    .cap_setfcap,
                };
                for (std_caps) |cap| {
                    try set.capabilities.append(allocator, cap);
                }
            },
            .privileged => {
                inline for (@typeInfo(Capability).@"enum".fields) |field| {
                    try set.capabilities.append(allocator, @enumFromInt(field.value));
                }
            },
        }
        return set;
    }
};

test "privilege capabilities setup" {
    const alloc = std.testing.allocator;

    var set_std = try CapabilitySet.initDefault(alloc, .standard);
    defer set_std.deinit(alloc);
    try std.testing.expect(set_std.capabilities.items.len == 14);

    var set_priv = try CapabilitySet.initDefault(alloc, .privileged);
    defer set_priv.deinit(alloc);
    try std.testing.expect(set_priv.capabilities.items.len == 19);
}

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
    mask: u64 = 0,

    pub fn init() CapabilitySet {
        return .{ .mask = 0 };
    }

    pub fn deinit(self: *CapabilitySet) void {
        self.mask = 0;
    }

    pub fn has(self: CapabilitySet, cap: Capability) bool {
        const shift: u6 = @intCast(@intFromEnum(cap));
        return (self.mask & (@as(u64, 1) << shift)) != 0;
    }

    pub fn add(self: *CapabilitySet, cap: Capability) void {
        const shift: u6 = @intCast(@intFromEnum(cap));
        self.mask |= (@as(u64, 1) << shift);
    }

    pub fn remove(self: *CapabilitySet, cap: Capability) void {
        const shift: u6 = @intCast(@intFromEnum(cap));
        self.mask &= ~(@as(u64, 1) << shift);
    }

    pub fn initDefault(level: PrivilegeLevel) CapabilitySet {
        var set = CapabilitySet.init();

        switch (level) {
            .restricted => {
                set.add(.cap_chown);
                set.add(.cap_net_bind_service);
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
                    set.add(cap);
                }
            },
            .privileged => {
                inline for (@typeInfo(Capability).@"enum".fields) |field| {
                    set.add(@enumFromInt(field.value));
                }
            },
        }
        return set;
    }
};

test "privilege capabilities setup" {
    var set_std = CapabilitySet.initDefault(.standard);
    defer set_std.deinit();
    try std.testing.expect(set_std.has(.cap_chown));
    try std.testing.expect(set_std.has(.cap_net_bind_service));
    try std.testing.expect(!set_std.has(.cap_sys_admin));

    var set_priv = CapabilitySet.initDefault(.privileged);
    defer set_priv.deinit();
    try std.testing.expect(set_priv.has(.cap_sys_admin));
}

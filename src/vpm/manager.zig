const std = @import("std");
const privilege = @import("../runtime/privilege.zig");
const policy_mod = @import("policy.zig");
const seccomp_mod = @import("seccomp.zig");

pub const PrivilegeLevel = privilege.PrivilegeLevel;
pub const PolicyEngine = policy_mod.PolicyEngine;
pub const SeccompGenerator = seccomp_mod.SeccompGenerator;

pub const VPMManager = struct {
    allocator: std.mem.Allocator,
    engine: PolicyEngine,

    pub fn init(allocator: std.mem.Allocator) VPMManager {
        return .{
            .allocator = allocator,
            .engine = PolicyEngine.init(allocator),
        };
    }

    pub fn deinit(self: *VPMManager) void {
        self.engine.deinit();
    }

    pub fn resolveEffectiveCapabilities(
        self: *VPMManager,
        level: PrivilegeLevel,
        exec_path: ?[]const u8,
    ) privilege.CapabilitySet {
        var base_set = privilege.CapabilitySet.initDefault(level);

        inline for (std.meta.fields(privilege.Capability)) |field| {
            const cap: privilege.Capability = @enumFromInt(field.value);
            const decision = self.engine.evaluate(level, cap, exec_path);
            if (decision.action == .allow) {
                base_set.add(cap);
            } else if (decision.action == .deny) {
                base_set.remove(cap);
            }
        }

        return base_set;
    }

    pub fn generateSeccompProfile(self: VPMManager, level: PrivilegeLevel) seccomp_mod.SeccompProfile {
        _ = self;
        return SeccompGenerator.generateDefaultProfile(level);
    }
};

test "VPMManager dynamic capability resolution and seccomp generation" {
    const alloc = std.testing.allocator;
    var manager = VPMManager.init(alloc);
    defer manager.deinit();

    try manager.engine.addRule(.{
        .capability = .cap_sys_admin,
        .action = .allow,
        .allowed_executable = "/bin/nginx",
    });

    var cap_set = manager.resolveEffectiveCapabilities(.restricted, "/bin/nginx");
    defer cap_set.deinit();

    try std.testing.expect(cap_set.has(.cap_sys_admin));

    const seccomp_prof = manager.generateSeccompProfile(.restricted);
    try std.testing.expectEqualStrings("SCMP_ACT_ERRNO", seccomp_prof.default_action);
}

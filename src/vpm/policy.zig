const std = @import("std");
const privilege = @import("../runtime/privilege.zig");

pub const Capability = privilege.Capability;
pub const PrivilegeLevel = privilege.PrivilegeLevel;

pub const Action = enum {
    allow,
    deny,
    audit,
};

pub const PolicyRule = struct {
    capability: Capability,
    action: Action,
    allowed_executable: ?[]const u8 = null,

    pub fn matches(self: PolicyRule, cap: Capability, exec_path: ?[]const u8) bool {
        if (self.capability != cap) return false;
        if (self.allowed_executable) |ae| {
            if (exec_path) |ep| {
                return std.mem.eql(u8, ae, ep);
            }
            return false;
        }
        return true;
    }
};

pub const PolicyDecision = struct {
    action: Action,
    reason: []const u8,
};

pub const PolicyEngine = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(PolicyRule),

    pub fn init(allocator: std.mem.Allocator) PolicyEngine {
        return .{
            .allocator = allocator,
            .rules = std.ArrayList(PolicyRule).empty,
        };
    }

    pub fn deinit(self: *PolicyEngine) void {
        for (self.rules.items) |r| {
            if (r.allowed_executable) |ae| self.allocator.free(ae);
        }
        self.rules.deinit(self.allocator);
    }

    pub fn addRule(self: *PolicyEngine, rule: PolicyRule) !void {
        var r = rule;
        if (rule.allowed_executable) |ae| {
            r.allowed_executable = try self.allocator.dupe(u8, ae);
        }
        try self.rules.append(self.allocator, r);
    }

    pub fn evaluate(
        self: PolicyEngine,
        level: PrivilegeLevel,
        requested_cap: Capability,
        exec_path: ?[]const u8,
    ) PolicyDecision {
        if (level == .privileged) {
            return .{ .action = .allow, .reason = "privileged profile grants all capabilities" };
        }

        if (level == .rootless) {
            return .{ .action = .deny, .reason = "rootless profile denies kernel capabilities" };
        }

        for (self.rules.items) |rule| {
            if (rule.matches(requested_cap, exec_path)) {
                return .{ .action = rule.action, .reason = "matched custom policy rule" };
            }
        }

        var cap_set = privilege.CapabilitySet.initDefault(self.allocator, level) catch return .{ .action = .deny, .reason = "failed to initialize baseline capabilities" };
        defer cap_set.deinit(self.allocator);

        if (cap_set.has(requested_cap)) {
            return .{ .action = .allow, .reason = "capability present in profile baseline" };
        }

        return .{ .action = .deny, .reason = "capability not permitted by profile or policy rules" };
    }
};

test "policy engine rule evaluation" {
    const alloc = std.testing.allocator;
    var engine = PolicyEngine.init(alloc);
    defer engine.deinit();

    try engine.addRule(.{
        .capability = .cap_sys_admin,
        .action = .allow,
        .allowed_executable = "/usr/bin/nginx",
    });

    const d1 = engine.evaluate(.restricted, .cap_sys_admin, "/usr/bin/nginx");
    try std.testing.expectEqual(Action.allow, d1.action);

    const d2 = engine.evaluate(.restricted, .cap_sys_admin, "/usr/bin/curl");
    try std.testing.expectEqual(Action.deny, d2.action);

    const d3 = engine.evaluate(.privileged, .cap_sys_admin, null);
    try std.testing.expectEqual(Action.allow, d3.action);
}

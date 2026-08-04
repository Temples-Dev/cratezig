const std = @import("std");
const privilege = @import("privilege.zig");
const CapabilitySet = privilege.CapabilitySet;
const PrivilegeLevel = privilege.PrivilegeLevel;

pub const OciNamespace = struct {
    type: []const u8,
    path: ?[]const u8 = null,
};

pub const OciUser = struct {
    uid: u32 = 0,
    gid: u32 = 0,
};

pub const OciCapabilities = struct {
    bounding: [][]const u8,
    effective: [][]const u8,
    inheritable: [][]const u8,
    permitted: [][]const u8,

    pub fn deinit(self: OciCapabilities, allocator: std.mem.Allocator) void {
        allocator.free(self.bounding);
        allocator.free(self.effective);
        allocator.free(self.inheritable);
        allocator.free(self.permitted);
    }
};

pub const OciProcess = struct {
    terminal: bool = false,
    user: OciUser = .{},
    args: [][]const u8,
    env: [][]const u8,
    cwd: []const u8 = "/",
    capabilities: OciCapabilities,
};

pub const OciRoot = struct {
    path: []const u8 = "rootfs",
    readonly: bool = false,
};

pub const OciLinux = struct {
    namespaces: []OciNamespace,
    maskedPaths: [][]const u8,
    readonlyPaths: [][]const u8,

    pub fn deinit(self: OciLinux, allocator: std.mem.Allocator) void {
        allocator.free(self.namespaces);
    }
};

pub const OciSpec = struct {
    ociVersion: []const u8 = "1.0.2",
    process: OciProcess,
    root: OciRoot = .{},
    linux: OciLinux,

    pub fn deinit(self: OciSpec, allocator: std.mem.Allocator) void {
        self.process.capabilities.deinit(allocator);
        self.linux.deinit(allocator);
    }
};

pub const SpecGenerator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SpecGenerator {
        return .{ .allocator = allocator };
    }

    pub fn generate(
        self: SpecGenerator,
        args: []const []const u8,
        env: []const []const u8,
        level: PrivilegeLevel,
    ) !OciSpec {
        var cap_set = try CapabilitySet.initDefault(self.allocator, level);
        defer cap_set.deinit(self.allocator);

        var caps_list = std.ArrayList([]const u8).empty;
        defer caps_list.deinit(self.allocator);

        for (cap_set.capabilities.items) |cap| {
            try caps_list.append(self.allocator, cap.toString());
        }

        const bounding = try self.allocator.dupe([]const u8, caps_list.items);
        errdefer self.allocator.free(bounding);

        const effective = try self.allocator.dupe([]const u8, caps_list.items);
        errdefer self.allocator.free(effective);

        const inheritable = try self.allocator.dupe([]const u8, caps_list.items);
        errdefer self.allocator.free(inheritable);

        const permitted = try self.allocator.dupe([]const u8, caps_list.items);
        errdefer self.allocator.free(permitted);

        var namespaces = std.ArrayList(OciNamespace).empty;
        defer namespaces.deinit(self.allocator);

        try namespaces.append(self.allocator, .{ .type = "pid" });
        try namespaces.append(self.allocator, .{ .type = "network" });
        try namespaces.append(self.allocator, .{ .type = "ipc" });
        try namespaces.append(self.allocator, .{ .type = "uts" });
        try namespaces.append(self.allocator, .{ .type = "mount" });

        if (level == .rootless) {
            try namespaces.append(self.allocator, .{ .type = "user" });
        }

        const ns_slice = try namespaces.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(ns_slice);

        var masked = std.ArrayList([]const u8).empty;
        defer masked.deinit(self.allocator);
        try masked.append(self.allocator, "/proc/kcore");
        try masked.append(self.allocator, "/proc/sysrq-trigger");

        var readonly = std.ArrayList([]const u8).empty;
        defer readonly.deinit(self.allocator);
        try readonly.append(self.allocator, "/proc/sys");
        try readonly.append(self.allocator, "/sys");

        return OciSpec{
            .process = .{
                .args = @constCast(args),
                .env = @constCast(env),
                .capabilities = .{
                    .bounding = bounding,
                    .effective = effective,
                    .inheritable = inheritable,
                    .permitted = permitted,
                },
            },
            .root = .{
                .readonly = (level == .restricted),
            },
            .linux = .{
                .namespaces = ns_slice,
                .maskedPaths = try masked.toOwnedSlice(self.allocator),
                .readonlyPaths = try readonly.toOwnedSlice(self.allocator),
            },
        };
    }
};

test "spec generator OCI output" {
    const alloc = std.testing.allocator;

    const gen = SpecGenerator.init(alloc);
    const args = [_][]const u8{"/bin/sh"};
    const env = [_][]const u8{"PATH=/bin"};

    var spec = try gen.generate(&args, &env, .standard);
    defer {
        alloc.free(spec.linux.maskedPaths);
        alloc.free(spec.linux.readonlyPaths);
        spec.deinit(alloc);
    }

    try std.testing.expectEqualStrings("1.0.2", spec.ociVersion);
    try std.testing.expect(spec.process.capabilities.bounding.len == 14);
    try std.testing.expect(spec.linux.namespaces.len == 5);
}

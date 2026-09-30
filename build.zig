const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("cratezig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "cratezig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cratezig", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the daemon or CLI wrapper").dependOn(&run_cmd.step);

    // Every source file stays at or under 500 lines.
    const loc = b.addSystemCommand(&.{ "sh", "scripts/check-loc.sh", "500" });
    b.step("lint", "Check per-file line limit").dependOn(&loc.step);

    const mod_tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    const exe_tests = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module }));
    const test_step = b.step("test", "Run unit tests and lint");
    test_step.dependOn(&mod_tests.step);
    test_step.dependOn(&exe_tests.step);
    test_step.dependOn(&loc.step);
}

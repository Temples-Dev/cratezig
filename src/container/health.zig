const std = @import("std");
const container_mod = @import("container.zig");

pub const HealthState = container_mod.HealthState;
pub const HealthCheckConfig = container_mod.HealthCheckConfig;

pub const HealthEvaluator = struct {
    pub fn evaluate(current: *HealthState, config: HealthCheckConfig, exit_code: i32) void {
        if (exit_code == 0) {
            current.status = .healthy;
            current.failing_streak = 0;
        } else {
            current.failing_streak += 1;
            if (current.failing_streak >= config.retries) {
                current.status = .unhealthy;
            } else if (current.status == .none) {
                current.status = .starting;
            }
        }
    }
};

test "health status evaluation logic" {
    var state = HealthState{ .status = .starting, .failing_streak = 0 };
    const config = HealthCheckConfig{
        .health_test = &.{"curl -f http://localhost/"},
        .retries = 3,
    };

    HealthEvaluator.evaluate(&state, config, 1);
    try std.testing.expectEqual(HealthState.Status.starting, state.status);
    try std.testing.expectEqual(@as(u32, 1), state.failing_streak);

    HealthEvaluator.evaluate(&state, config, 1);
    try std.testing.expectEqual(@as(u32, 2), state.failing_streak);

    HealthEvaluator.evaluate(&state, config, 1);
    try std.testing.expectEqual(HealthState.Status.unhealthy, state.status);
    try std.testing.expectEqual(@as(u32, 3), state.failing_streak);

    HealthEvaluator.evaluate(&state, config, 0);
    try std.testing.expectEqual(HealthState.Status.healthy, state.status);
    try std.testing.expectEqual(@as(u32, 0), state.failing_streak);
}

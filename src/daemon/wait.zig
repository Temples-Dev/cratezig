const std = @import("std");
const Container = @import("../container/container.zig").Container;

pub const Condition = enum {
    not_running,
    next_exit,
    removed,

    pub fn parse(s: ?[]const u8) !Condition {
        const v = s orelse return .not_running;
        if (v.len == 0 or std.mem.eql(u8, v, "not-running")) return .not_running;
        if (std.mem.eql(u8, v, "next-exit")) return .next_exit;
        if (std.mem.eql(u8, v, "removed")) return .removed;
        return error.InvalidParameter;
    }
};

/// Blocks until `cond` holds and returns the container's exit code.
pub fn containerWait(ctr: *Container, cond: Condition) i32 {
    ctr.lock();
    defer ctr.unlock();
    const start_seq = ctr.exit_seq;
    while (true) {
        const done = switch (cond) {
            .not_running => !ctr.state.running or ctr.removed,
            .next_exit => ctr.exit_seq != start_seq or ctr.removed,
            .removed => ctr.removed,
        };
        if (done) return ctr.state.exit_code;
        ctr.waitChange();
    }
}

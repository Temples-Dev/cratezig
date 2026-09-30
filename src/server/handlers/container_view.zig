//! Docker Engine API views of a container: the summary returned by
//! GET /containers/json (what `docker ps` renders).
const std = @import("std");
const Container = @import("../../container/container.zig").Container;
const ContainerState = @import("../../container/container.zig").ContainerState;
const timefmt = @import("../../util/timefmt.zig");

pub const Summary = struct {
    ctr: *Container,
    now_ns: i128,

    pub fn jsonStringify(self: Summary, jws: anytype) !void {
        const c = self.ctr;
        try jws.beginObject();
        try jws.objectField("Id");
        try jws.write(c.id[0..]);
        try jws.objectField("Names");
        var name_buf: [80]u8 = undefined;
        try jws.write(&[_][]const u8{std.fmt.bufPrint(&name_buf, "/{s}", .{c.name}) catch c.name});
        try jws.objectField("Image");
        try jws.write(c.image_name);
        try jws.objectField("ImageID");
        try jws.write(c.image_id);
        try jws.objectField("Command");
        try writeCommand(jws, c);
        try jws.objectField("Created");
        try jws.write(@divFloor(c.created_at, std.time.ns_per_s));
        try jws.objectField("State");
        try jws.write(@tagName(c.state.status));
        try jws.objectField("Status");
        var buf: [96]u8 = undefined;
        try jws.write(status(&buf, c.state, self.now_ns));
        try jws.objectField("Ports");
        try jws.beginArray();
        try jws.endArray();
        try jws.objectField("Labels");
        try jws.beginObject();
        var it = c.config.labels.iterator();
        while (it.next()) |e| {
            try jws.objectField(e.key_ptr.*);
            try jws.write(e.value_ptr.*);
        }
        try jws.endObject();
        try jws.objectField("HostConfig");
        try jws.write(.{ .NetworkMode = c.host_config.network_mode });
        try jws.objectField("Mounts");
        try jws.beginArray();
        try jws.endArray();
        try jws.endObject();
    }
};

fn writeCommand(jws: anytype, c: *const Container) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var first = true;
    for ([_][]const []const u8{ c.config.entrypoint, c.config.cmd }) |part| {
        for (part) |arg| {
            if (!first) w.writeByte(' ') catch break;
            w.writeAll(arg) catch break;
            first = false;
        }
    }
    try jws.write(w.buffered());
}

/// GET /containers/{id}/json (`docker inspect`). Caller holds the lock.
pub const Inspect = struct {
    ctr: *Container,

    pub fn jsonStringify(self: Inspect, jws: anytype) !void {
        const c = self.ctr;
        var t1: [40]u8 = undefined;
        var t2: [40]u8 = undefined;
        var t3: [40]u8 = undefined;
        var name_buf: [80]u8 = undefined;
        const st = c.state;

        try jws.beginObject();
        try jws.objectField("Id");
        try jws.write(c.id[0..]);
        try jws.objectField("Created");
        try jws.write(timefmt.rfc3339(&t1, c.created_at));
        // Path is the first word of entrypoint+cmd, Args the rest.
        var words: [2][]const []const u8 = .{ c.config.entrypoint, c.config.cmd };
        const path_src: usize = if (words[0].len > 0) 0 else 1;
        try jws.objectField("Path");
        try jws.write(if (words[path_src].len > 0) words[path_src][0] else "");
        if (words[path_src].len > 0) words[path_src] = words[path_src][1..];
        try jws.objectField("Args");
        try jws.beginArray();
        for (words) |part| for (part) |arg| try jws.write(arg);
        try jws.endArray();
        try jws.objectField("State");
        try jws.write(.{
            .Status = @tagName(st.status),
            .Running = st.running,
            .Paused = st.paused,
            .Restarting = st.restarting,
            .OOMKilled = st.oom_killed,
            .Dead = st.dead,
            .Pid = st.pid,
            .ExitCode = st.exit_code,
            .Error = "",
            .StartedAt = timefmt.rfc3339(&t2, st.started_at),
            .FinishedAt = timefmt.rfc3339(&t3, st.finished_at),
        });
        try jws.objectField("Image");
        try jws.write(c.image_id);
        try jws.objectField("Name");
        try jws.write(std.fmt.bufPrint(&name_buf, "/{s}", .{c.name}) catch c.name);
        try jws.objectField("RestartCount");
        try jws.write(c.restart_count);
        try jws.objectField("Driver");
        try jws.write("overlay2");
        try jws.objectField("Platform");
        try jws.write("linux");
        try jws.objectField("HostConfig");
        try jws.write(c.host_config);
        try jws.objectField("Config");
        try jws.write(c.config);
        try jws.objectField("NetworkSettings");
        try jws.write(c.network_settings);
        try jws.objectField("Mounts");
        try jws.write(.{});
        try jws.endObject();
    }
};

/// Docker's human status column: "Up 5 minutes", "Exited (0) 2 hours ago".
pub fn status(buf: []u8, st: ContainerState, now_ns: i128) []const u8 {
    var dur_buf: [32]u8 = undefined;
    return switch (st.status) {
        .running => std.fmt.bufPrint(buf, "Up {s}", .{humanDuration(&dur_buf, now_ns - st.started_at)}),
        .paused => std.fmt.bufPrint(buf, "Up {s} (Paused)", .{humanDuration(&dur_buf, now_ns - st.started_at)}),
        .restarting => std.fmt.bufPrint(buf, "Restarting ({d}) {s} ago", .{ st.exit_code, humanDuration(&dur_buf, now_ns - st.finished_at) }),
        .exited => if (st.finished_at > 0)
            std.fmt.bufPrint(buf, "Exited ({d}) {s} ago", .{ st.exit_code, humanDuration(&dur_buf, now_ns - st.finished_at) })
        else
            std.fmt.bufPrint(buf, "Exited ({d})", .{st.exit_code}),
        .created => std.fmt.bufPrint(buf, "Created", .{}),
        .removing => std.fmt.bufPrint(buf, "Removal In Progress", .{}),
        .dead => std.fmt.bufPrint(buf, "Dead", .{}),
    } catch "";
}

/// Mirrors go-units HumanDuration.
pub fn humanDuration(buf: []u8, ns: i128) []const u8 {
    const s = @max(@divFloor(ns, std.time.ns_per_s), 0);
    const r = if (s < 1)
        std.fmt.bufPrint(buf, "Less than a second", .{})
    else if (s == 1)
        std.fmt.bufPrint(buf, "1 second", .{})
    else if (s < 60)
        std.fmt.bufPrint(buf, "{d} seconds", .{s})
    else if (@divFloor(s, 60) == 1)
        std.fmt.bufPrint(buf, "About a minute", .{})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d} minutes", .{@divFloor(s, 60)})
    else if (@divFloor(s + 1800, 3600) == 1)
        std.fmt.bufPrint(buf, "About an hour", .{})
    else if (s < 48 * 3600)
        std.fmt.bufPrint(buf, "{d} hours", .{@divFloor(s + 1800, 3600)})
    else if (s < 7 * 24 * 3600 * 2)
        std.fmt.bufPrint(buf, "{d} days", .{@divFloor(s, 24 * 3600)})
    else if (s < 30 * 24 * 3600 * 3)
        std.fmt.bufPrint(buf, "{d} weeks", .{@divFloor(s, 7 * 24 * 3600)})
    else if (s < 365 * 24 * 3600 * 2)
        std.fmt.bufPrint(buf, "{d} months", .{@divFloor(s, 30 * 24 * 3600)})
    else
        std.fmt.bufPrint(buf, "{d} years", .{@divFloor(s, 365 * 24 * 3600)});
    return r catch "";
}

test "status strings match docker ps" {
    var buf: [96]u8 = undefined;
    const now: i128 = 1_000_000 * std.time.ns_per_s;
    try std.testing.expectEqualStrings("Up 5 minutes", status(&buf, .{ .status = .running, .started_at = now - 300 * std.time.ns_per_s }, now));
    try std.testing.expectEqualStrings("Exited (137) About an hour ago", status(&buf, .{ .status = .exited, .exit_code = 137, .finished_at = now - 3700 * std.time.ns_per_s }, now));
    try std.testing.expectEqualStrings("Created", status(&buf, .{}, now));
}

//! GET /events — replays buffered events, then streams new ones as JSON lines.
const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const events = @import("../../events/events.zig");
const StoredEvent = events.StoredEvent;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const Conn = @import("../response.zig").Conn;

/// Docker `filters` subset: type, event (action), container (id or name).
const Filters = struct {
    type: []const []const u8 = &.{},
    event: []const []const u8 = &.{},
    container: []const []const u8 = &.{},

    fn anyMatch(values: []const []const u8, candidates: []const ?[]const u8) bool {
        if (values.len == 0) return true;
        for (values) |v| for (candidates) |c| {
            if (c) |x| if (std.mem.eql(u8, v, x) or (v.len >= 12 and std.mem.startsWith(u8, x, v))) return true;
        };
        return false;
    }

    fn match(self: Filters, ev: *const StoredEvent) bool {
        return anyMatch(self.type, &.{@tagName(ev.event_type)}) and
            anyMatch(self.event, &.{ev.action.slice()}) and
            anyMatch(self.container, &.{ ev.actor_id.slice(), ev.attr("name") });
    }
};

/// Docker sends filters as {"key":["v"]} or the legacy {"key":{"v":true}}.
fn parseFilters(alloc: std.mem.Allocator, raw: ?[]const u8) !Filters {
    var out: Filters = .{};
    const text = raw orelse return out;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
    const obj = if (parsed == .object) parsed.object else return error.InvalidParameter;
    inline for (.{ "type", "event", "container" }) |key| {
        if (obj.get(key)) |v| {
            var list = std.ArrayList([]const u8).empty;
            switch (v) {
                .array => |arr| for (arr.items) |item| if (item == .string) try list.append(alloc, item.string),
                .object => |o| {
                    var it = o.iterator();
                    while (it.next()) |e| try list.append(alloc, e.key_ptr.*);
                },
                else => return error.InvalidParameter,
            }
            @field(out, key) = list.items;
        }
    }
    return out;
}

/// Unix seconds (optionally fractional) → ns. Docker's CLI sends this form.
fn parseTime(raw: ?[]const u8) !?i128 {
    const s = raw orelse return null;
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse s.len;
    const secs = try std.fmt.parseInt(i64, s[0..dot], 10);
    return @as(i128, secs) * std.time.ns_per_s;
}

const Ctx = struct {
    daemon: *Daemon,
    filters: Filters,
    since: ?i128,
    until: ?i128,
    sub: *events.Subscriber,

    fn emit(self: *Ctx, w: *std.Io.Writer, ev: *const StoredEvent) !void {
        if (!self.filters.match(ev)) return;
        if (self.since) |t| if (ev.time_nano < t) return;
        try std.json.Stringify.value(ev.*, .{}, w);
        try w.writeByte('\n');
        try w.flush();
    }

    fn run(p: *anyopaque, conn: Conn) anyerror!void {
        const self: *Ctx = @ptrCast(@alignCast(p));
        // Replay history only when asked, as Docker does.
        if (self.since != null) {
            const past = try self.daemon.events.getEvents(self.daemon.allocator);
            defer self.daemon.allocator.free(past);
            for (past) |*ev| {
                if (self.until) |u| if (ev.time_nano > u) break;
                try self.emit(conn.writer, ev);
            }
        }
        if (self.until != null) return;
        while (self.sub.receive()) |ev| try self.emit(conn.writer, &ev);
    }

    fn cleanup(p: *anyopaque) void {
        const self: *Ctx = @ptrCast(@alignCast(p));
        self.daemon.events.unsubscribe(self.sub);
    }
};

pub fn stream(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const filters = parseFilters(alloc, req.query.get("filters")) catch return Response.badRequest("invalid filters");
    const since = parseTime(req.query.get("since")) catch return Response.badRequest("invalid since");
    const until = parseTime(req.query.get("until")) catch return Response.badRequest("invalid until");
    const ctx = alloc.create(Ctx) catch return Response.internalError("out of memory");
    // Subscribe before replaying so nothing published in between is lost.
    const sub = daemon.events.subscribe() catch return Response.internalError("out of memory");
    ctx.* = .{ .daemon = daemon, .filters = filters, .since = since, .until = until, .sub = sub };
    return Response.streaming("application/json", .{ .ctx = ctx, .run = Ctx.run, .cleanup = Ctx.cleanup });
}

test "filters accept both docker encodings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f1 = try parseFilters(a, "{\"type\":[\"container\"],\"event\":{\"start\":true}}");
    var ev = StoredEvent.from(.{ .event_type = .container, .action = "start", .actor_id = "abc", .time_nano = 1 });
    try std.testing.expect(f1.match(&ev));
    ev = StoredEvent.from(.{ .event_type = .container, .action = "die", .actor_id = "abc", .time_nano = 1 });
    try std.testing.expect(!f1.match(&ev));
    try std.testing.expectEqual(@as(?i128, 5 * std.time.ns_per_s), try parseTime("5.123"));
}

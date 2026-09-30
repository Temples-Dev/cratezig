const std = @import("std");

pub const EventType = enum {
    container,
    image,
    network,
    volume,
    daemon,
    plugin,
};

pub const Attr = struct {
    key: []const u8,
    value: []const u8,
};

/// Input to `Events.publish`. All slices are borrowed only for the duration
/// of the call; the event bus stores its own copy.
pub const Event = struct {
    event_type: EventType,
    action: []const u8,
    actor_id: []const u8,
    attrs: []const Attr = &.{},
    time_nano: i128,
};

fn FixedStr(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: usize = 0,

        fn init(s: []const u8) @This() {
            var out: @This() = .{};
            out.len = @min(s.len, cap);
            @memcpy(out.buf[0..out.len], s[0..out.len]);
            return out;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

const max_attrs = 4;

/// Self-contained copy of an event, safe to keep after the publisher's
/// memory is gone.
pub const StoredEvent = struct {
    event_type: EventType,
    time_nano: i128,
    action: FixedStr(32),
    actor_id: FixedStr(64),
    attr_keys: [max_attrs]FixedStr(16) = undefined,
    attr_vals: [max_attrs]FixedStr(128) = undefined,
    attr_len: usize = 0,

    pub fn from(ev: Event) StoredEvent {
        var out = StoredEvent{
            .event_type = ev.event_type,
            .time_nano = ev.time_nano,
            .action = .init(ev.action),
            .actor_id = .init(ev.actor_id),
        };
        for (ev.attrs[0..@min(ev.attrs.len, max_attrs)]) |a| {
            out.attr_keys[out.attr_len] = .init(a.key);
            out.attr_vals[out.attr_len] = .init(a.value);
            out.attr_len += 1;
        }
        return out;
    }

    pub fn attr(self: *const StoredEvent, key: []const u8) ?[]const u8 {
        for (0..self.attr_len) |i| {
            if (std.mem.eql(u8, self.attr_keys[i].slice(), key)) return self.attr_vals[i].slice();
        }
        return null;
    }

    pub fn jsonStringify(self: StoredEvent, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Type");
        try jws.write(@tagName(self.event_type));
        try jws.objectField("Action");
        try jws.write(self.action.slice());

        try jws.objectField("Actor");
        try jws.beginObject();
        try jws.objectField("ID");
        try jws.write(self.actor_id.slice());
        try jws.objectField("Attributes");
        try jws.beginObject();
        for (0..self.attr_len) |i| {
            try jws.objectField(self.attr_keys[i].slice());
            try jws.write(self.attr_vals[i].slice());
        }
        try jws.endObject();
        try jws.endObject();

        try jws.objectField("time");
        try jws.write(@as(i64, @intCast(@divTrunc(self.time_nano, 1_000_000_000))));
        try jws.objectField("timeNano");
        try jws.write(@as(i64, @intCast(self.time_nano)));
        try jws.objectField("scope");
        try jws.write("local");
        try jws.endObject();
    }
};

fn RingQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity]T = undefined,
        head: usize = 0,
        len: usize = 0,

        pub fn push(self: *Self, item: T) error{Full}!void {
            if (self.len == capacity) return error.Full;
            self.buf[(self.head + self.len) % capacity] = item;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return item;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len == capacity;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }
    };
}

pub const Subscriber = struct {
    io: std.Io,
    queue: RingQueue(StoredEvent, 64) = .{},
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    closed: bool = false,

    pub fn init(io: std.Io) Subscriber {
        return .{ .io = io };
    }

    pub fn receive(self: *Subscriber) ?StoredEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.queue.isEmpty() and !self.closed) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }

        return self.queue.pop();
    }

    pub fn close(self: *Subscriber) void {
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }
};

pub const Events = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    ring: [256]StoredEvent = undefined,
    ring_head: usize = 0,
    ring_count: usize = 0,

    subscribers: std.ArrayList(*Subscriber),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Events {
        return .{
            .io = io,
            .allocator = allocator,
            .subscribers = std.ArrayList(*Subscriber).empty,
        };
    }

    pub fn deinit(self: *Events) void {
        self.subscribers.deinit(self.allocator);
    }

    pub fn publish(self: *Events, ev: Event) void {
        const event = StoredEvent.from(ev);
        self.mutex.lockUncancelable(self.io);
        self.ring[self.ring_head % 256] = event;
        self.ring_head +%= 1;
        if (self.ring_count < 256) self.ring_count += 1;
        // Deliver while holding the bus lock so unsubscribe cannot free a
        // subscriber mid-delivery.
        defer self.mutex.unlock(self.io);
        for (self.subscribers.items) |sub| {
            sub.mutex.lockUncancelable(sub.io);
            sub.queue.push(event) catch {};
            sub.cond.signal(sub.io);
            sub.mutex.unlock(sub.io);
        }
    }

    pub fn subscribe(self: *Events) !*Subscriber {
        const sub = try self.allocator.create(Subscriber);
        sub.* = Subscriber.init(self.io);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.subscribers.append(self.allocator, sub);

        return sub;
    }

    pub fn getEvents(self: *Events, allocator: std.mem.Allocator) ![]StoredEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var list = try std.ArrayList(StoredEvent).initCapacity(allocator, self.ring_count);
        errdefer list.deinit(allocator);

        var i: usize = 0;
        while (i < self.ring_count) : (i += 1) {
            const index = if (self.ring_count < 256) i else (self.ring_head + i - self.ring_count) % 256;
            try list.append(allocator, self.ring[index]);
        }

        return try list.toOwnedSlice(allocator);
    }

    pub fn unsubscribe(self: *Events, sub: *Subscriber) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.subscribers.items, 0..) |s, i| {
            if (s == sub) {
                _ = self.subscribers.swapRemove(i);
                break;
            }
        }

        sub.close();
        self.allocator.destroy(sub);
    }
};

const std = @import("std");

pub const EventType = enum {
    container,
    image,
    network,
    volume,
    daemon,
    plugin,
};

pub const Event = struct {
    event_type: EventType,
    action: []const u8,
    actor_id: []const u8,
    actor_attrs: std.StringHashMap([]const u8),
    time_nano: i128,
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
    queue: RingQueue(Event, 64) = .{},
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    closed: bool = false,

    pub fn init(io: std.Io) Subscriber {
        return .{ .io = io };
    }

    pub fn receive(self: *Subscriber) ?Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.queue.isEmpty() and !self.closed) {
            self.cond.wait(self.io, &self.mutex);
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

    ring: [256]Event = undefined,
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

    pub fn publish(self: *Events, event: Event) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.ring[self.ring_head % 256] = event;
        self.ring_head +%= 1;
        if (self.ring_count < 256) self.ring_count += 1;

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

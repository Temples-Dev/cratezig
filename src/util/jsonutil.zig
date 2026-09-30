//! Type-checked accessors for `std.json.Value`. Loaders use these instead of
//! `.string`/`.integer` field access, which panics on unexpected types.
const std = @import("std");

pub fn str(val: ?std.json.Value) ?[]const u8 {
    return switch (val orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn int(val: ?std.json.Value) ?i64 {
    return switch (val orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

pub fn boolean(val: ?std.json.Value) ?bool {
    return switch (val orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

pub fn object(val: ?std.json.Value) ?std.json.ObjectMap {
    return switch (val orelse return null) {
        .object => |o| o,
        else => null,
    };
}

/// Copies a JSON array of strings; non-string items become "".
pub fn strings(a: std.mem.Allocator, val: ?std.json.Value) ![]const []const u8 {
    const arr = switch (val orelse return &.{}) {
        .array => |x| x,
        else => return &.{},
    };
    const out = try a.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| out[i] = try a.dupe(u8, str(item) orelse "");
    return out;
}

/// Copies the keys of a JSON object (e.g. Docker's `ExposedPorts`).
pub fn keys(a: std.mem.Allocator, val: ?std.json.Value) ![]const []const u8 {
    const obj = object(val) orelse return &.{};
    const out = try a.alloc([]const u8, obj.count());
    var it = obj.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) out[i] = try a.dupe(u8, e.key_ptr.*);
    return out;
}

test "accessors reject wrong types instead of panicking" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"s":"x","n":1,"b":true,"a":["p",2],"o":{"80/tcp":{}}}
    , .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqualStrings("x", str(o.get("s")).?);
    try std.testing.expectEqual(null, str(o.get("n")));
    try std.testing.expectEqual(@as(i64, 1), int(o.get("n")).?);
    try std.testing.expectEqual(null, int(o.get("missing")));
    try std.testing.expect(boolean(o.get("b")).?);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arr = try strings(arena.allocator(), o.get("a"));
    try std.testing.expectEqualStrings("", arr[1]);
    const ks = try keys(arena.allocator(), o.get("o"));
    try std.testing.expectEqualStrings("80/tcp", ks[0]);
}

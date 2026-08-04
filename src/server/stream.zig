const std = @import("std");

pub const StreamType = enum(u8) {
    stdin = 0,
    stdout = 1,
    stderr = 2,
};

pub const MultiplexWriter = struct {
    pub fn writeFrame(allocator: std.mem.Allocator, list: *std.ArrayList(u8), stream_type: StreamType, payload: []const u8) !void {
        var header: [8]u8 = undefined;
        header[0] = @intFromEnum(stream_type);
        header[1] = 0;
        header[2] = 0;
        header[3] = 0;
        const len: u32 = @intCast(payload.len);
        std.mem.writeInt(u32, header[4..8], len, .big);

        try list.appendSlice(allocator, &header);
        try list.appendSlice(allocator, payload);
    }
};

test "multiplex writer 8-byte frame header encoding" {
    const alloc = std.testing.allocator;
    var out_buf = std.ArrayList(u8).empty;
    defer out_buf.deinit(alloc);

    try MultiplexWriter.writeFrame(alloc, &out_buf, .stdout, "hello container");

    try std.testing.expect(out_buf.items.len == 8 + 15);
    try std.testing.expectEqual(@as(u8, 1), out_buf.items[0]);
    const payload_size = std.mem.readInt(u32, out_buf.items[4..8], .big);
    try std.testing.expectEqual(@as(u32, 15), payload_size);
    try std.testing.expectEqualStrings("hello container", out_buf.items[8..]);
}

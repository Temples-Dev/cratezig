const std = @import("std");

pub const CompressionType = enum {
    uncompressed,
    gzip,
    zstd,
};

pub const OciExporter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OciExporter {
        return .{ .allocator = allocator };
    }

    /// Generates a tar stream for a given snapshot directory on-demand.
    pub fn exportSnapshotTar(self: OciExporter, snapshot_path: []const u8, compression: CompressionType, writer: anytype) !void {
        _ = self;
        _ = snapshot_path;
        _ = compression;

        // Write zero-length dummy tar header as initial stub for on-demand stream
        var header: [512]u8 = undefined;
        @memset(&header, 0);
        try writer.writeAll(&header);
    }
};

test "oci exporter initialization" {
    const alloc = std.testing.allocator;
    const exporter = OciExporter.init(alloc);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try exporter.exportSnapshotTar("/tmp", .uncompressed, fbs.writer());
    try std.testing.expect(fbs.getWritten().len > 0);
}

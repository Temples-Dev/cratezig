const std = @import("std");

pub const BuildContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    context_dir: []const u8,
    checksum: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, context_dir: []const u8) !BuildContext {
        const hash = try computeDirectoryChecksum(allocator, io, context_dir);
        return .{
            .allocator = allocator,
            .io = io,
            .context_dir = try allocator.dupe(u8, context_dir),
            .checksum = hash,
        };
    }

    pub fn deinit(self: *BuildContext) void {
        self.allocator.free(self.context_dir);
        self.allocator.free(self.checksum);
    }

    pub fn copyFile(self: *BuildContext, src_rel: []const u8, dest_abs: []const u8) !void {
        var src_buf: [512]u8 = undefined;
        const src_path = try std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ self.context_dir, src_rel });

        var src_file = try std.Io.Dir.openFileAbsolute(self.io, src_path, .{});
        defer src_file.close(self.io);

        var dest_file = try std.Io.Dir.createFileAbsolute(self.io, dest_abs, .{});
        defer dest_file.close(self.io);

        var buf: [8192]u8 = undefined;
        var reader = src_file.reader(self.io, &buf);

        while (true) {
            const chunk = try reader.interface.readAlloc(self.allocator, 8192);
            if (chunk.len == 0) break;
            defer self.allocator.free(chunk);
            _ = try dest_file.writer(self.io).write(chunk);
        }
    }

    fn computeDirectoryChecksum(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]const u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(dir_path);

        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
            var digest: [32]u8 = undefined;
            hasher.final(&digest);
            var hex: [64]u8 = undefined;
            @memcpy(&hex, std.fmt.bytesToHex(digest, .lower)[0..64]);
            return try std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            hasher.update(entry.name);
        }

        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        var hex: [64]u8 = undefined;
        @memcpy(&hex, std.fmt.bytesToHex(digest, .lower)[0..64]);
        return try std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
    }
};

test "context directory checksum" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var ctx = try BuildContext.init(alloc, io, "/tmp");
    defer ctx.deinit();

    try std.testing.expect(ctx.checksum.len > 0);
}

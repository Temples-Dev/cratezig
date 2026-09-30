//! Read-only image layers as overlay2 directories, keyed by chain ID:
//!
//!   <data-root>/overlay2/<chain-hex>/diff       unpacked layer contents
//!   <data-root>/overlay2/<chain-hex>/link       short id, e.g. "K3J5…"
//!   <data-root>/overlay2/<chain-hex>/lower      "l/<parent>:l/<grandparent>…"
//!   <data-root>/overlay2/<chain-hex>/committed  present once fully unpacked
//!   <data-root>/overlay2/l/<short> -> ../<chain-hex>/diff
//!
//! Short links keep overlay mount options under the one-page limit.
const std = @import("std");
const content = @import("content.zig");
const fsutil = @import("../util/fsutil.zig");

const Digest = [7 + 64]u8;

/// chain[0] = diff[0]; chain[i] = sha256(chain[i-1] + " " + diff[i]).
pub fn chainIds(a: std.mem.Allocator, diff_ids: []const []const u8) ![]Digest {
    const out = try a.alloc(Digest, diff_ids.len);
    for (diff_ids, 0..) |d, i| {
        if (d.len != 71) return error.InvalidDigest;
        if (i == 0) {
            @memcpy(&out[0], d);
            continue;
        }
        var buf: [71 + 1 + 71]u8 = undefined;
        out[i] = content.digestOf(try std.fmt.bufPrint(&buf, "{s} {s}", .{ &out[i - 1], d }));
    }
    return out;
}

pub const Store = struct {
    io: std.Io,
    data_root: []const u8,

    fn path(self: *const Store, buf: []u8, chain: []const u8, sub: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/overlay2/{s}{s}", .{ self.data_root, content.hex(chain), sub });
    }

    pub fn exists(self: *const Store, chain: []const u8) bool {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const p = self.path(&buf, chain, "/committed") catch return false;
        std.Io.Dir.cwd().access(self.io, p, .{}) catch return false;
        return true;
    }

    /// Creates an empty layer directory wired to `parent`, discarding any
    /// half-unpacked leftovers. Returns the `diff` path (in `buf`).
    pub fn prepare(self: *const Store, buf: []u8, chain: []const u8, parent: ?[]const u8) ![]const u8 {
        const io = self.io;
        var tmp: [std.Io.Dir.max_path_bytes]u8 = undefined;
        std.Io.Dir.cwd().deleteTree(io, try self.path(&tmp, chain, "")) catch {};
        const diff = try self.path(buf, chain, "/diff");
        try std.Io.Dir.createDirPath(.cwd(), io, diff);

        var short: [26]u8 = undefined;
        try randomShort(io, &short);
        try fsutil.writeFileAtomic(io, try self.path(&tmp, chain, "/link"), &short);
        var link_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const link_path = try std.fmt.bufPrint(&link_path_buf, "{s}/overlay2/l/{s}", .{ self.data_root, &short });
        var target_buf: [128]u8 = undefined;
        try std.Io.Dir.cwd().symLink(io, try std.fmt.bufPrint(&target_buf, "../{s}/diff", .{content.hex(chain)}), link_path, .{});

        if (parent) |p| {
            var lower_buf: [4096]u8 = undefined;
            try fsutil.writeFileAtomic(io, try self.path(&tmp, chain, "/lower"), try self.lowerFor(&lower_buf, p));
        }
        return diff;
    }

    pub fn commit(self: *const Store, chain: []const u8) !void {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try fsutil.writeFileAtomic(self.io, try self.path(&buf, chain, "/committed"), "");
    }

    pub fn abort(self: *const Store, chain: []const u8) void {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir = self.path(&buf, chain, "") catch return;
        std.Io.Dir.cwd().deleteTree(self.io, dir) catch {};
    }

    /// The `lower` value for something stacked directly on `top`:
    /// "l/<top>" followed by top's own lower chain.
    pub fn lowerFor(self: *const Store, buf: []u8, top: []const u8) ![]const u8 {
        var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var link: [64]u8 = undefined;
        const short = try readSmall(self.io, try self.path(&p, top, "/link"), &link);
        var rest: [4096]u8 = undefined;
        const lower = readSmall(self.io, try self.path(&p, top, "/lower"), &rest) catch |err| switch (err) {
            error.FileNotFound => return std.fmt.bufPrint(buf, "l/{s}", .{short}),
            else => return err,
        };
        return std.fmt.bufPrint(buf, "l/{s}:{s}", .{ short, lower });
    }
};

fn readSmall(io: std.Io, path: []const u8, buf: []u8) ![]const u8 {
    return std.mem.trim(u8, try std.Io.Dir.cwd().readFile(io, path, buf), " \n");
}

fn randomShort(io: std.Io, out: *[26]u8) !void {
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var bytes: [26]u8 = undefined;
    try io.randomSecure(&bytes);
    for (out, bytes) |*c, b| c.* = chars[b % chars.len];
}

test "chain ids follow the OCI definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const d1 = "sha256:" ++ "1" ** 64;
    const d2 = "sha256:" ++ "2" ** 64;
    const chain = try chainIds(arena.allocator(), &.{ d1, d2 });
    try std.testing.expectEqualStrings(d1, &chain[0]);
    try std.testing.expectEqualStrings(&content.digestOf(d1 ++ " " ++ d2), &chain[1]);
}

test "prepare wires lower chains through short links" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    try tmp.dir.createDirPath(io, "overlay2/l");

    const store: Store = .{ .io = io, .data_root = root };
    const c1 = "sha256:" ++ "a" ** 64;
    const c2 = "sha256:" ++ "b" ** 64;
    var b1: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = try store.prepare(&b1, c1, null);
    try store.commit(c1);
    _ = try store.prepare(&b1, c2, c1);
    try std.testing.expect(store.exists(c1));
    try std.testing.expect(!store.exists(c2));

    var lb: [4096]u8 = undefined;
    const lower = try store.lowerFor(&lb, c2);
    // "l/<c2 link>:l/<c1 link>"
    try std.testing.expectEqual(@as(usize, 2 + 26 + 1 + 2 + 26), lower.len);
    store.abort(c2);
    try std.testing.expect(!store.exists(c2));
}

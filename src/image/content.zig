//! Content-addressed blob store: `<data-root>/content/blobs/sha256/<hex>`.
//! Blobs are written to `ingest/` first and only renamed into place after
//! their sha256 matches the expected digest.
const std = @import("std");
const reference = @import("reference.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{ DigestMismatch, SizeMismatch, InvalidDigest };

pub fn digestOf(data: []const u8) [7 + 64]u8 {
    var sum: [32]u8 = undefined;
    Sha256.hash(data, &sum, .{});
    return format(sum);
}

pub fn format(sum: [32]u8) [7 + 64]u8 {
    var out: [7 + 64]u8 = undefined;
    @memcpy(out[0..7], "sha256:");
    out[7..].* = std.fmt.bytesToHex(sum, .lower);
    return out;
}

pub fn hex(digest: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, digest, "sha256:")) digest[7..] else digest;
}

pub const Store = struct {
    io: std.Io,
    /// `<data-root>/content`
    root: []const u8,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, data_root: []const u8) !Store {
        const root = try std.fmt.allocPrint(gpa, "{s}/content", .{data_root});
        errdefer gpa.free(root);
        for ([_][]const u8{ "/blobs/sha256", "/ingest" }) |sub| {
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            try std.Io.Dir.createDirPath(.cwd(), io, try std.fmt.bufPrint(&buf, "{s}{s}", .{ root, sub }));
        }
        return .{ .io = io, .root = root };
    }

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        gpa.free(self.root);
    }

    pub fn blobPath(self: *const Store, digest: []const u8, buf: []u8) ![]const u8 {
        if (!reference.validDigest(digest)) return error.InvalidDigest;
        return std.fmt.bufPrint(buf, "{s}/blobs/sha256/{s}", .{ self.root, hex(digest) });
    }

    pub fn has(self: *const Store, digest: []const u8) bool {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = self.blobPath(digest, &buf) catch return false;
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        return true;
    }

    pub fn readAlloc(self: *const Store, gpa: std.mem.Allocator, digest: []const u8, limit: usize) ![]u8 {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        return std.Io.Dir.cwd().readFileAlloc(self.io, try self.blobPath(digest, &buf), gpa, .limited(limit));
    }

    /// Stores an in-memory blob (manifests, configs) after verifying it.
    pub fn put(self: *const Store, digest: []const u8, data: []const u8) !void {
        var w = try self.ingest(digest, data.len);
        defer w.abort();
        try w.write(data);
        try w.commit();
    }

    pub fn ingest(self: *const Store, digest: []const u8, size: ?u64) !Ingest {
        if (!reference.validDigest(digest)) return error.InvalidDigest;
        var w: Ingest = .{ .store = self, .expected = undefined, .expected_size = size, .file = undefined, .tmp_path = undefined };
        @memcpy(&w.expected, digest[0 .. 7 + 64]);
        var rand: [8]u8 = undefined;
        try self.io.randomSecure(&rand);
        const tmp = try std.fmt.bufPrint(&w.tmp_buf, "{s}/ingest/{s}-{x}", .{ self.root, hex(digest), rand });
        w.tmp_path = tmp;
        w.file = try std.Io.Dir.createFileAbsolute(self.io, tmp, .{ .exclusive = true });
        return w;
    }
};

/// A blob being written. Call `commit` on success; `abort` is always safe.
pub const Ingest = struct {
    store: *const Store,
    expected: [7 + 64]u8,
    expected_size: ?u64,
    file: std.Io.File,
    tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    tmp_path: []const u8,
    hasher: Sha256 = .init(.{}),
    written: u64 = 0,
    done: bool = false,

    pub fn write(self: *Ingest, data: []const u8) !void {
        if (self.expected_size) |max| if (self.written + data.len > max) return error.SizeMismatch;
        try self.file.writePositionalAll(self.store.io, data, self.written);
        self.hasher.update(data);
        self.written += data.len;
    }

    pub fn commit(self: *Ingest) !void {
        if (self.expected_size) |want| if (self.written != want) return error.SizeMismatch;
        var sum: [32]u8 = undefined;
        self.hasher.final(&sum);
        if (!std.mem.eql(u8, &format(sum), &self.expected)) return error.DigestMismatch;
        try self.file.sync(self.store.io);
        self.file.close(self.store.io);
        self.done = true;
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try std.Io.Dir.rename(.cwd(), self.tmp_path, .cwd(), try self.store.blobPath(&self.expected, &buf), self.store.io);
    }

    pub fn abort(self: *Ingest) void {
        if (self.done) return;
        self.done = true;
        self.file.close(self.store.io);
        std.Io.Dir.deleteFileAbsolute(self.store.io, self.tmp_path) catch {};
    }
};

test "ingest verifies digest and size before publishing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    var store = try Store.init(io, gpa, root);
    defer store.deinit(gpa);

    const good = digestOf("hello");
    try store.put(&good, "hello");
    try std.testing.expect(store.has(&good));
    const back = try store.readAlloc(gpa, &good, 100);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("hello", back);

    const other = digestOf("other");
    try std.testing.expectError(error.DigestMismatch, store.put(&other, "tampered"));
    try std.testing.expect(!store.has(&other));
    var w = try store.ingest(&other, 5);
    defer w.abort();
    try std.testing.expectError(error.SizeMismatch, w.write("other plus more"));
    try std.testing.expectError(error.InvalidDigest, store.put("sha256:nope", "x"));
}

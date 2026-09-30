//! Streaming tar reader with everything image layers need and std.tar
//! drops: ownership, hardlinks, device nodes, mtimes and PAX xattrs.
const std = @import("std");

pub const Kind = enum { file, directory, symlink, hardlink, char_device, block_device, fifo };

pub const Xattr = struct { name: []const u8, value: []const u8 };

pub const Entry = struct {
    kind: Kind,
    name: []const u8,
    link: []const u8 = "",
    mode: u32 = 0o644,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u64 = 0,
    mtime: i64 = 0,
    dev_major: u32 = 0,
    dev_minor: u32 = 0,
    xattrs: []const Xattr = &.{},
};

pub const Error = error{ InvalidTar, UnsupportedTarEntry, OutOfMemory } || std.Io.Reader.Error;

pub const Reader = struct {
    in: *std.Io.Reader,
    /// Holds names/xattrs of the current entry; reset on every `next`.
    arena: std.heap.ArenaAllocator,
    /// Body bytes of the current entry not yet consumed, plus block padding.
    remaining: u64 = 0,
    padding: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, in: *std.Io.Reader) Reader {
        return .{ .in = in, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Reader) void {
        self.arena.deinit();
    }

    /// Reader for the current entry's body. Must be fully consumed or left
    /// alone; `next` skips whatever is left.
    pub fn body(self: *Reader, buf: []u8) !usize {
        const n = try self.in.readSliceShort(buf[0..@intCast(@min(buf.len, self.remaining))]);
        if (n == 0 and self.remaining > 0) return error.EndOfStream;
        self.remaining -= n;
        return n;
    }

    pub fn next(self: *Reader) Error!?Entry {
        try self.in.discardAll64(self.remaining + self.padding);
        self.remaining = 0;
        self.padding = 0;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        var long_name: ?[]const u8 = null;
        var long_link: ?[]const u8 = null;
        var pax: Pax = .{};
        while (true) {
            var hdr: [512]u8 = undefined;
            const n = try self.in.readSliceShort(&hdr);
            if (n == 0) return null;
            if (n < 512) return error.InvalidTar;
            if (std.mem.allEqual(u8, &hdr, 0)) return null; // end-of-archive marker
            if (!checksumOk(&hdr)) return error.InvalidTar;

            const size = try number(hdr[124..136]);
            const pad = (512 - size % 512) % 512;
            switch (hdr[156]) {
                'L', 'K', 'x' => {
                    if (size > 1 << 20) return error.InvalidTar;
                    const data = try a.alloc(u8, @intCast(size));
                    try self.in.readSliceAll(data);
                    try self.in.discardAll64(pad);
                    switch (hdr[156]) {
                        'L' => long_name = std.mem.sliceTo(data, 0),
                        'K' => long_link = std.mem.sliceTo(data, 0),
                        else => try pax.parse(a, data),
                    }
                    continue;
                },
                'g' => { // global PAX header: nothing we use
                    try self.in.discardAll64(size + pad);
                    continue;
                },
                else => {},
            }

            var e: Entry = .{
                .kind = switch (hdr[156]) {
                    '0', 0, '7' => .file,
                    '1' => .hardlink,
                    '2' => .symlink,
                    '3' => .char_device,
                    '4' => .block_device,
                    '5' => .directory,
                    '6' => .fifo,
                    else => return error.UnsupportedTarEntry,
                },
                // Copy out of `hdr`, which is reused by the next read.
                .name = long_name orelse try ustarName(a, &hdr),
                .link = long_link orelse try a.dupe(u8, field(hdr[157..257])),
                .mode = @intCast(try number(hdr[100..108]) & 0o7777),
                .uid = @intCast(try number(hdr[108..116])),
                .gid = @intCast(try number(hdr[116..124])),
                .size = size,
                .mtime = @intCast(try number(hdr[136..148])),
                .dev_major = @intCast(try number(hdr[329..337])),
                .dev_minor = @intCast(try number(hdr[337..345])),
            };
            pax.apply(&e);
            if (e.kind == .file) {
                self.remaining = e.size;
                self.padding = (512 - e.size % 512) % 512;
            } else {
                e.size = 0;
                try self.in.discardAll64(size + pad);
            }
            return e;
        }
    }
};

const Pax = struct {
    path: ?[]const u8 = null,
    linkpath: ?[]const u8 = null,
    size: ?u64 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    mtime: ?i64 = null,
    xattrs: std.ArrayList(Xattr) = .empty,

    /// Records are "<len> <key>=<value>\n".
    fn parse(self: *Pax, a: std.mem.Allocator, data: []const u8) !void {
        var rest = data;
        while (rest.len > 0) {
            const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidTar;
            const len = std.fmt.parseInt(usize, rest[0..sp], 10) catch return error.InvalidTar;
            if (len <= sp + 1 or len > rest.len or rest[len - 1] != '\n') return error.InvalidTar;
            const rec = rest[sp + 1 .. len - 1];
            rest = rest[len..];
            const eq = std.mem.indexOfScalar(u8, rec, '=') orelse return error.InvalidTar;
            const key = rec[0..eq];
            const val = rec[eq + 1 ..];
            if (std.mem.eql(u8, key, "path")) self.path = val;
            if (std.mem.eql(u8, key, "linkpath")) self.linkpath = val;
            if (std.mem.eql(u8, key, "size")) self.size = std.fmt.parseInt(u64, val, 10) catch return error.InvalidTar;
            if (std.mem.eql(u8, key, "uid")) self.uid = std.fmt.parseInt(u32, val, 10) catch return error.InvalidTar;
            if (std.mem.eql(u8, key, "gid")) self.gid = std.fmt.parseInt(u32, val, 10) catch return error.InvalidTar;
            if (std.mem.eql(u8, key, "mtime")) {
                const dot = std.mem.indexOfScalar(u8, val, '.') orelse val.len;
                self.mtime = std.fmt.parseInt(i64, val[0..dot], 10) catch return error.InvalidTar;
            }
            if (std.mem.startsWith(u8, key, "SCHILY.xattr.")) {
                try self.xattrs.append(a, .{ .name = key["SCHILY.xattr.".len..], .value = val });
            }
        }
    }

    fn apply(self: *const Pax, e: *Entry) void {
        if (self.path) |v| e.name = v;
        if (self.linkpath) |v| e.link = v;
        if (self.size) |v| e.size = v;
        if (self.uid) |v| e.uid = v;
        if (self.gid) |v| e.gid = v;
        if (self.mtime) |v| e.mtime = v;
        e.xattrs = self.xattrs.items;
    }
};

fn field(bytes: []const u8) []const u8 {
    return std.mem.sliceTo(bytes, 0);
}

fn ustarName(a: std.mem.Allocator, hdr: *const [512]u8) ![]const u8 {
    const name = field(hdr[0..100]);
    const prefix = if (std.mem.eql(u8, hdr[257..262], "ustar")) field(hdr[345..500]) else "";
    if (prefix.len == 0) return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, name });
}

/// Octal, or GNU base-256 when the high bit of the first byte is set.
fn number(bytes: []const u8) error{InvalidTar}!u64 {
    if (bytes[0] & 0x80 != 0) {
        var v: u64 = bytes[0] & 0x7f;
        for (bytes[1..]) |b| {
            if (v >> 56 != 0) return error.InvalidTar;
            v = (v << 8) | b;
        }
        return v;
    }
    const s = std.mem.trim(u8, field(bytes), " ");
    if (s.len == 0) return 0;
    return std.fmt.parseInt(u64, s, 8) catch error.InvalidTar;
}

fn checksumOk(hdr: *const [512]u8) bool {
    const want = number(hdr[148..156]) catch return false;
    var sum: u64 = 0;
    for (hdr, 0..) |b, i| sum += if (i >= 148 and i < 156) ' ' else b;
    return sum == want;
}

// --- test helpers -----------------------------------------------------------

pub fn testHeader(buf: *[512]u8, name: []const u8, typeflag: u8, size: u64, link: []const u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..name.len], name);
    _ = std.fmt.bufPrint(buf[100..107], "{o:0>7}", .{@as(u32, 0o755)}) catch unreachable;
    _ = std.fmt.bufPrint(buf[108..115], "{o:0>7}", .{@as(u32, 1000)}) catch unreachable;
    _ = std.fmt.bufPrint(buf[116..123], "{o:0>7}", .{@as(u32, 1000)}) catch unreachable;
    _ = std.fmt.bufPrint(buf[124..135], "{o:0>11}", .{size}) catch unreachable;
    _ = std.fmt.bufPrint(buf[136..147], "{o:0>11}", .{@as(u64, 1700000000)}) catch unreachable;
    buf[156] = typeflag;
    @memcpy(buf[157 .. 157 + link.len], link);
    @memcpy(buf[257..263], "ustar\x00");
    @memset(buf[148..156], ' ');
    var sum: u32 = 0;
    for (buf) |b| sum += b;
    _ = std.fmt.bufPrint(buf[148..155], "{o:0>6}\x00", .{sum}) catch unreachable;
}

test "reads files, links, pax overrides and skips unread bodies" {
    var tar: [512 * 8]u8 = @splat(0);
    testHeader(tar[0..512], "dir/", '5', 0, "");
    const pax = "29 path=dir/a-very-long-name\n" ++ "15 uid=4294967\n";
    testHeader(tar[512..1024], "PaxHeader", 'x', pax.len, "");
    @memcpy(tar[1024 .. 1024 + pax.len], pax);
    testHeader(tar[1536..2048], "dir/short", '0', 5, "");
    @memcpy(tar[2048..2053], "hello");
    testHeader(tar[2560..3072], "dir/ln", '2', 0, "short");

    var r = std.Io.Reader.fixed(&tar);
    var tr = Reader.init(std.testing.allocator, &r);
    defer tr.deinit();

    const d = (try tr.next()).?;
    try std.testing.expectEqual(Kind.directory, d.kind);
    try std.testing.expectEqual(@as(u32, 1000), d.uid);
    const f = (try tr.next()).?;
    try std.testing.expectEqualStrings("dir/a-very-long-name", f.name);
    try std.testing.expectEqual(@as(u32, 4294967), f.uid);
    try std.testing.expectEqual(@as(u64, 5), f.size); // body not read: next() skips it
    const l = (try tr.next()).?;
    try std.testing.expectEqual(Kind.symlink, l.kind);
    try std.testing.expectEqualStrings("short", l.link);
    try std.testing.expectEqual(null, try tr.next());
}

test "rejects corrupted headers" {
    var tar: [1024]u8 = @splat(0);
    testHeader(tar[0..512], "f", '0', 0, "");
    tar[0] = 'g'; // checksum no longer matches
    var r = std.Io.Reader.fixed(&tar);
    var tr = Reader.init(std.testing.allocator, &r);
    defer tr.deinit();
    try std.testing.expectError(error.InvalidTar, tr.next());
}

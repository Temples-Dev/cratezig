//! Extracts an image layer tar into an empty overlay `diff` directory.
//!
//! Safety: every parent directory is opened one component at a time from the
//! layer root with O_NOFOLLOW, so neither ".." nor a symlinked parent can make
//! an entry land outside the root. OCI whiteouts become overlayfs whiteouts.
const std = @import("std");
const linux = std.os.linux;
const tarx = @import("tarx.zig");

pub const Error = error{ UnsafePath, UnpackFailed, AccessDenied, FileNotFound, PathAlreadyExists } ||
    tarx.Error || std.fmt.BufPrintError;

pub const Stats = struct { bytes: u64 = 0, skipped_privileged: u32 = 0 };

const whiteout_prefix = ".wh.";
const opaque_marker = ".wh..wh..opq";

pub fn apply(gpa: std.mem.Allocator, root_path: []const u8, in: *std.Io.Reader) Error!Stats {
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_z = try std.fmt.bufPrintZ(&root_buf, "{s}", .{root_path});
    const root = try check(linux.open(root_z, .{ .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0));
    defer _ = linux.close(@intCast(root));

    var u: Unpacker = .{ .root = @intCast(root), .privileged = linux.geteuid() == 0 };
    var tr = tarx.Reader.init(gpa, in);
    defer tr.deinit();
    while (try tr.next()) |e| try u.entry(&tr, e);
    return u.stats;
}

const Unpacker = struct {
    root: i32,
    privileged: bool,
    stats: Stats = .{},
    buf: [64 * 1024]u8 = undefined,

    fn entry(self: *Unpacker, tr: *tarx.Reader, e: tarx.Entry) Error!void {
        var comps_buf: [256][]const u8 = undefined;
        const comps = try splitClean(e.name, &comps_buf);
        if (comps.len == 0) return; // "./" itself
        const base = comps[comps.len - 1];

        const parent = try self.openParent(comps[0 .. comps.len - 1], true);
        defer if (parent != self.root) closeFd(parent);

        var name_buf: [256]u8 = undefined;
        if (std.mem.eql(u8, base, opaque_marker)) {
            return self.privilegedOp(linux.fsetxattr(parent, "trusted.overlay.opaque", "y", 1, 0));
        }
        if (std.mem.startsWith(u8, base, whiteout_prefix)) {
            const target = try std.fmt.bufPrintZ(&name_buf, "{s}", .{base[whiteout_prefix.len..]});
            return self.privilegedOp(linux.mknodat(parent, target, linux.S.IFCHR, 0));
        }

        const name = try std.fmt.bufPrintZ(&name_buf, "{s}", .{base});
        if (e.kind != .directory) _ = linux.unlinkat(parent, name, 0); // replace duplicates

        switch (e.kind) {
            .directory => {
                const rc = linux.mkdirat(parent, name, 0o755);
                if (linux.errno(rc) != .SUCCESS and linux.errno(rc) != .EXIST) return errnoErr(linux.errno(rc));
                const fd = try openNoFollow(parent, name, .{ .DIRECTORY = true });
                defer closeFd(fd);
                try self.meta(fd, e);
            },
            .file => {
                const fd = try check(linux.openat(parent, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600));
                defer closeFd(@intCast(fd));
                while (true) {
                    const n = try tr.body(&self.buf);
                    if (n == 0) break;
                    try writeAll(@intCast(fd), self.buf[0..n]);
                    self.stats.bytes += n;
                }
                try self.meta(@intCast(fd), e);
            },
            .symlink => {
                var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const link = try std.fmt.bufPrintZ(&link_buf, "{s}", .{e.link});
                _ = try check(linux.symlinkat(link, parent, name));
                try self.privilegedOp(linux.fchownat(parent, name, e.uid, e.gid, linux.AT.SYMLINK_NOFOLLOW));
            },
            .hardlink => {
                var tcomps_buf: [256][]const u8 = undefined;
                const tcomps = try splitClean(e.link, &tcomps_buf);
                if (tcomps.len == 0) return error.UnsafePath;
                const tparent = try self.openParent(tcomps[0 .. tcomps.len - 1], false);
                defer if (tparent != self.root) closeFd(tparent);
                var tname_buf: [256]u8 = undefined;
                const tname = try std.fmt.bufPrintZ(&tname_buf, "{s}", .{tcomps[tcomps.len - 1]});
                _ = try check(linux.linkat(tparent, tname, parent, name, 0));
            },
            .char_device, .block_device, .fifo => {
                const typ: u32 = switch (e.kind) {
                    .char_device => linux.S.IFCHR,
                    .block_device => linux.S.IFBLK,
                    else => linux.S.IFIFO,
                };
                try self.privilegedOp(linux.mknodat(parent, name, typ | e.mode, makedev(e.dev_major, e.dev_minor)));
                try self.privilegedOp(linux.fchownat(parent, name, e.uid, e.gid, linux.AT.SYMLINK_NOFOLLOW));
            },
        }
    }

    /// Ownership, mode (after chown, which clears setuid bits), xattrs, mtime.
    fn meta(self: *Unpacker, fd: i32, e: tarx.Entry) Error!void {
        try self.privilegedOp(linux.fchown(fd, e.uid, e.gid));
        _ = try check(linux.fchmod(fd, e.mode));
        for (e.xattrs) |x| {
            var name_buf: [256]u8 = undefined;
            const xname = try std.fmt.bufPrintZ(&name_buf, "{s}", .{x.name});
            try self.privilegedOp(linux.fsetxattr(fd, xname, x.value.ptr, x.value.len, 0));
        }
        if (e.kind == .file) {
            const ts: [2]linux.timespec = .{ .{ .sec = e.mtime, .nsec = 0 }, .{ .sec = e.mtime, .nsec = 0 } };
            _ = linux.utimensat(fd, null, &ts, 0);
        }
    }

    /// Operations only root can do (chown to other users, device nodes,
    /// trusted.* xattrs). Unprivileged runs skip them and count the skip.
    fn privilegedOp(self: *Unpacker, rc: usize) Error!void {
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .PERM, .ACCES => if (self.privileged) return error.AccessDenied else {
                self.stats.skipped_privileged += 1;
            },
            else => |err| return errnoErr(err),
        }
    }

    /// Walks `comps` from the root without following symlinks, creating
    /// missing directories when `create` is set. Returns an fd the caller
    /// closes unless it is `self.root`.
    fn openParent(self: *Unpacker, comps: []const []const u8, create: bool) Error!i32 {
        var fd = self.root;
        errdefer if (fd != self.root) closeFd(fd);
        for (comps) |c| {
            var buf: [256]u8 = undefined;
            const name = try std.fmt.bufPrintZ(&buf, "{s}", .{c});
            const next = openNoFollow(fd, name, .{ .DIRECTORY = true }) catch |err| switch (err) {
                error.FileNotFound => if (create) blk: {
                    _ = try check(linux.mkdirat(fd, name, 0o755));
                    break :blk try openNoFollow(fd, name, .{ .DIRECTORY = true });
                } else return err,
                else => return err,
            };
            if (fd != self.root) closeFd(fd);
            fd = next;
        }
        return fd;
    }
};

/// Normalizes a tar path into components; rejects anything that climbs out.
fn splitClean(path: []const u8, out: *[256][]const u8) Error![]const []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..") or c.len > 255) return error.UnsafePath;
        if (n == out.len) return error.UnsafePath;
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

fn openNoFollow(dir: i32, name: [*:0]const u8, flags: linux.O) Error!i32 {
    var f = flags;
    f.NOFOLLOW = true;
    f.CLOEXEC = true;
    return @intCast(try check(linux.openat(dir, name, f, 0)));
}

fn closeFd(fd: i32) void {
    _ = linux.close(fd);
}

fn writeAll(fd: i32, data: []const u8) Error!void {
    var rest = data;
    while (rest.len > 0) {
        const n = try check(linux.write(fd, rest.ptr, rest.len));
        rest = rest[n..];
    }
}

fn makedev(major: u32, minor: u32) u32 {
    return ((major & 0xfff) << 8) | (minor & 0xff) | ((minor & 0xfff00) << 12);
}

fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        else => |e| errnoErr(e),
    };
}

fn errnoErr(e: linux.E) Error {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .LOOP, .NOTDIR => error.UnsafePath, // a symlink where a directory must be
        .PERM, .ACCES => error.AccessDenied,
        else => error.UnpackFailed,
    };
}

// --- tests ------------------------------------------------------------------

fn buildTar(out: []u8, entries: []const struct { name: []const u8, typ: u8, body: []const u8 = "", link: []const u8 = "" }) []u8 {
    var off: usize = 0;
    for (entries) |e| {
        tarx.testHeader(out[off..][0..512], e.name, e.typ, e.body.len, e.link);
        off += 512;
        @memcpy(out[off .. off + e.body.len], e.body);
        off += (e.body.len + 511) / 512 * 512;
    }
    @memset(out[off .. off + 1024], 0);
    return out[0 .. off + 1024];
}

fn tmpRoot(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(std.testing.io, buf)];
}

test "extracts files, dirs, symlinks and hardlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    var storage: [512 * 16]u8 = undefined;
    const tar = buildTar(&storage, &.{
        .{ .name = "./etc/", .typ = '5' },
        .{ .name = "etc/hostname", .typ = '0', .body = "box\n" },
        .{ .name = "etc/hn-link", .typ = '1', .link = "etc/hostname" },
        .{ .name = "etc/sym", .typ = '2', .link = "hostname" },
        .{ .name = "deep/implicit/file", .typ = '0', .body = "x" },
    });
    var r = std.Io.Reader.fixed(tar);
    const stats = try apply(std.testing.allocator, root, &r);
    try std.testing.expectEqual(@as(u64, 5), stats.bytes);

    const io = std.testing.io;
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("box\n", try tmp.dir.readFile(io, "etc/hn-link", &buf));
    try std.testing.expectEqualStrings("hostname", buf[0..try tmp.dir.readLink(io, "etc/sym", &buf)]);
    try std.testing.expectEqualStrings("x", try tmp.dir.readFile(io, "deep/implicit/file", &buf));
}

test "refuses to escape the root via .. or symlinked parents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    var storage: [512 * 8]u8 = undefined;
    var r1 = std.Io.Reader.fixed(buildTar(&storage, &.{.{ .name = "../evil", .typ = '0', .body = "x" }}));
    try std.testing.expectError(error.UnsafePath, apply(std.testing.allocator, root, &r1));

    var r2 = std.Io.Reader.fixed(buildTar(&storage, &.{
        .{ .name = "escape", .typ = '2', .link = "/tmp" },
        .{ .name = "escape/owned", .typ = '0', .body = "x" },
    }));
    try std.testing.expectError(error.UnsafePath, apply(std.testing.allocator, root, &r2));
}

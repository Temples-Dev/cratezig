//! POST /images/create?fromImage=…&tag=… — pulls, streaming Docker's JSON
//! progress messages so `docker pull` renders its usual output.
const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const pull_mod = @import("../../image/pull.zig");
const registry = @import("../../image/registry.zig");
const reference = @import("../../image/reference.zig");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const Conn = @import("../response.zig").Conn;

const Ctx = struct {
    daemon: *Daemon,
    ref: []const u8,
    display: []const u8,
    tag: []const u8,
    /// "alpine:latest" form for the final status line.
    familiar: []const u8,
    creds: ?registry.Credentials,
    w: *std.Io.Writer = undefined,
    failed: bool = false,

    fn line(self: *Ctx, value: anytype) void {
        if (self.failed) return;
        std.json.Stringify.value(value, .{}, self.w) catch return self.fail();
        self.w.writeAll("\r\n") catch return self.fail();
        self.w.flush() catch return self.fail();
    }

    fn fail(self: *Ctx) void {
        self.failed = true; // client went away; finish the pull anyway
    }

    fn emit(p: *anyopaque, id: []const u8, status: []const u8, current: u64, total: u64) void {
        const self: *Ctx = @ptrCast(@alignCast(p));
        if (total > 0) {
            self.line(.{ .status = status, .progressDetail = .{ .current = current, .total = total }, .id = id });
        } else {
            self.line(.{ .status = status, .progressDetail = struct {}{}, .id = id });
        }
    }

    fn run(p: *anyopaque, conn: Conn) anyerror!void {
        const self: *Ctx = @ptrCast(@alignCast(p));
        self.w = conn.writer;
        var msg_buf: [512]u8 = undefined;
        self.line(.{ .status = std.fmt.bufPrint(&msg_buf, "Pulling from {s}", .{self.display}) catch "Pulling", .id = self.tag });

        const d = self.daemon;
        const result = pull_mod.pull(&d.images, self.ref, .{
            .creds = self.creds,
            .insecure_registries = d.config.insecure_registries,
        }, .{ .ctx = self, .emitFn = emit }) catch |err| {
            const msg = errorMessage(&msg_buf, err, self.ref);
            self.line(.{ .errorDetail = .{ .message = msg }, .@"error" = msg });
            return;
        };
        self.line(.{ .status = std.fmt.bufPrint(&msg_buf, "Digest: {s}", .{&result.digest}) catch "" });
        const verb = if (result.up_to_date) "Image is up to date for" else "Downloaded newer image for";
        self.line(.{ .status = std.fmt.bufPrint(&msg_buf, "Status: {s} {s}", .{ verb, self.familiar }) catch "" });
    }
};

fn errorMessage(buf: []u8, err: anyerror, ref: []const u8) []const u8 {
    return switch (err) {
        error.ManifestNotFound => std.fmt.bufPrint(buf, "manifest for {s} not found: manifest unknown", .{ref}),
        error.RegistryUnauthorized => std.fmt.bufPrint(buf, "pull access denied for {s}, repository does not exist or may require 'docker login'", .{ref}),
        error.NoMatchingPlatform => std.fmt.bufPrint(buf, "no matching manifest for linux in the manifest list entries", .{}),
        error.DigestMismatch, error.DiffIdMismatch => std.fmt.bufPrint(buf, "content verification failed for {s}: {s}", .{ ref, @errorName(err) }),
        else => std.fmt.bufPrint(buf, "pull {s} failed: {s}", .{ ref, @errorName(err) }),
    } catch "pull failed";
}

/// X-Registry-Auth: base64url(JSON {username, password, identitytoken}).
fn parseAuth(alloc: std.mem.Allocator, header: ?[]const u8) ?registry.Credentials {
    const raw = std.mem.trim(u8, header orelse return null, " ");
    if (raw.len == 0) return null;
    const dec = std.base64.url_safe_no_pad.Decoder;
    const trimmed = std.mem.trimEnd(u8, raw, "=");
    const buf = alloc.alloc(u8, dec.calcSizeForSlice(trimmed) catch return null) catch return null;
    dec.decode(buf, trimmed) catch return null;
    const Auth = struct { username: []const u8 = "", password: []const u8 = "", identitytoken: []const u8 = "" };
    const auth = std.json.parseFromSliceLeaky(Auth, alloc, buf, .{ .ignore_unknown_fields = true }) catch return null;
    if (auth.username.len == 0 and auth.identitytoken.len == 0) return null;
    return .{ .username = auth.username, .password = auth.password, .identity_token = auth.identitytoken };
}

pub fn pull(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const from = req.query.get("fromImage") orelse return Response.badRequest("missing fromImage");
    if (req.query.get("fromSrc") != null) return Response.notImplemented("docker import is not supported by cratezig yet");
    const tag = req.query.get("tag") orelse "";
    const joined = if (tag.len == 0)
        from
    else if (std.mem.startsWith(u8, tag, "sha256:"))
        std.fmt.allocPrint(alloc, "{s}@{s}", .{ from, tag }) catch return Response.internalError("out of memory")
    else
        std.fmt.allocPrint(alloc, "{s}:{s}", .{ from, tag }) catch return Response.internalError("out of memory");
    const ref = reference.parse(alloc, joined) catch return Response.badRequest("invalid reference format");

    const ctx = alloc.create(Ctx) catch return Response.internalError("out of memory");
    ctx.* = .{
        .daemon = daemon,
        .ref = joined,
        .display = ref.repository,
        .tag = ref.digest orelse ref.tag,
        .familiar = if (ref.digest) |d| std.fmt.allocPrint(alloc, "{s}@{s}", .{ ref.familiarName(), d }) catch joined else blk: {
            var buf: [512]u8 = undefined;
            break :blk alloc.dupe(u8, ref.familiarTag(&buf) catch joined) catch joined;
        },
        .creds = parseAuth(alloc, req.header("x-registry-auth")),
    };
    return Response.streaming("application/json", .{ .ctx = ctx, .run = Ctx.run });
}

test "X-Registry-Auth decoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // base64url of {"username":"u","password":"p"}
    const c = parseAuth(arena.allocator(), "eyJ1c2VybmFtZSI6InUiLCJwYXNzd29yZCI6InAifQ==").?;
    try std.testing.expectEqualStrings("u", c.username);
    try std.testing.expectEqualStrings("p", c.password);
    try std.testing.expectEqual(null, parseAuth(arena.allocator(), "e30=")); // {}
}

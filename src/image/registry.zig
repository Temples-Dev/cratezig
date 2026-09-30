//! Docker Registry HTTP API v2 client: bearer/basic auth, manifests, blobs.
const std = @import("std");
const http = std.http;
const Reference = @import("reference.zig").Reference;
const content = @import("content.zig");
const manifest = @import("manifest.zig");
const ju = @import("../util/jsonutil.zig");

pub const Credentials = struct {
    username: []const u8 = "",
    password: []const u8 = "",
    /// OAuth refresh token from `docker login` (identitytoken).
    identity_token: []const u8 = "",
};

pub const Error = error{ RegistryUnauthorized, ManifestNotFound, RegistryError, ManifestTooLarge };

pub const Fetched = struct {
    content_type: []const u8,
    body: []u8,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    http: http.Client,
    ref: Reference,
    creds: ?Credentials,
    /// Plain HTTP (insecure registry, or localhost).
    plain_http: bool,
    /// "Bearer <token>" or "Basic <b64>" once authenticated. Replaced (never
    /// freed early) on re-auth so concurrent downloads can keep using an old
    /// value; all values are freed in deinit.
    auth: ?[]u8 = null,
    auth_history: std.ArrayList([]u8) = .empty,
    auth_mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, ref: Reference, creds: ?Credentials, plain_http: bool) Client {
        return .{ .gpa = gpa, .http = .{ .allocator = gpa, .io = io }, .ref = ref, .creds = creds, .plain_http = plain_http };
    }

    pub fn deinit(self: *Client) void {
        for (self.auth_history.items) |a| self.gpa.free(a);
        self.auth_history.deinit(self.gpa);
        self.http.deinit();
    }

    fn currentAuth(self: *Client) ?[]const u8 {
        self.auth_mutex.lockUncancelable(self.http.io);
        defer self.auth_mutex.unlock(self.http.io);
        return self.auth;
    }

    /// Fetches a manifest or index and verifies it against `expected` when
    /// the reference is a digest (or the registry's Docker-Content-Digest).
    pub fn getManifest(self: *Client, alloc: std.mem.Allocator, ref_or_digest: []const u8) !Fetched {
        var url_buf: [1024]u8 = undefined;
        const target = try self.endpoint(&url_buf, "manifests", ref_or_digest);
        var sink: MemorySink = .{ .alloc = alloc, .limit = 4 * 1024 * 1024 };
        try self.get(target, manifest.media.accept, &sink);
        const body = try sink.body.toOwnedSlice(alloc);
        const actual = content.digestOf(body);
        const expected = if (std.mem.startsWith(u8, ref_or_digest, "sha256:")) ref_or_digest else sink.digest;
        if (expected) |d| if (!std.mem.eql(u8, d, &actual)) return content.Error.DigestMismatch;
        return .{ .content_type = sink.content_type orelse "", .body = body };
    }

    /// Streams a blob into the content store, verifying digest and size.
    /// `progress` is called with the running byte count.
    pub fn fetchBlob(self: *Client, store: *const content.Store, desc: manifest.Descriptor, progress: anytype) !void {
        if (store.has(desc.digest)) return;
        var url_buf: [1024]u8 = undefined;
        const target = try self.endpoint(&url_buf, "blobs", desc.digest);
        var w = try store.ingest(desc.digest, desc.size);
        defer w.abort();
        var sink: BlobSink(@TypeOf(progress)) = .{ .ingest = &w, .progress = progress };
        try self.get(target, null, &sink);
        try w.commit();
    }

    fn endpoint(self: *Client, buf: []u8, kind: []const u8, ref: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}://{s}/v2/{s}/{s}/{s}", .{
            if (self.plain_http) "http" else "https", self.ref.apiHost(), self.ref.repository, kind, ref,
        });
    }

    /// GET with one authentication retry and manual redirects. `sink`
    /// receives `head()` then `chunk()`s.
    fn get(self: *Client, first_target: []const u8, accept: ?[]const u8, sink: anytype) !void {
        var target_buf: [8 * 1024]u8 = undefined;
        var target: []const u8 = first_target;
        var retried_auth = false;
        var send_auth = true;
        var redirects: u8 = 0;
        while (true) {
            var extra_buf: [1]http.Header = undefined;
            const extra: []const http.Header = if (accept) |acc| blk: {
                extra_buf[0] = .{ .name = "Accept", .value = acc };
                break :blk extra_buf[0..1];
            } else &.{};
            const current = self.currentAuth();
            const auth: http.Client.Request.Headers.Value = if (send_auth and current != null) .{ .override = current.? } else .omit;

            var req = try self.http.request(.GET, try std.Uri.parse(target), .{
                .extra_headers = extra,
                .redirect_behavior = .unhandled,
                .headers = .{ .accept_encoding = .{ .override = "identity" }, .authorization = auth },
            });
            defer req.deinit();
            try req.sendBodiless();
            var res = try req.receiveHead(&.{});

            switch (res.head.status) {
                .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => {
                    redirects += 1;
                    if (redirects > 5) return error.RegistryError;
                    const loc = res.head.location orelse return error.RegistryError;
                    if (loc.len > target_buf.len) return error.RegistryError;
                    // Docker Hub sends blobs to a CDN: never forward the
                    // registry token to another host.
                    const old_host = hostOf(target);
                    @memmove(target_buf[0..loc.len], loc);
                    target = target_buf[0..loc.len];
                    if (!std.mem.eql(u8, hostOf(target), old_host)) send_auth = false;
                    continue;
                },
                .unauthorized => {
                    if (retried_auth or !send_auth) return error.RegistryUnauthorized;
                    retried_auth = true;
                    const challenge = header(res.head, "www-authenticate") orelse return error.RegistryUnauthorized;
                    const owned = try self.gpa.dupe(u8, challenge);
                    defer self.gpa.free(owned);
                    try self.authenticate(owned);
                    continue;
                },
                .ok => {},
                .forbidden => return error.RegistryUnauthorized,
                .not_found => return error.ManifestNotFound,
                else => {
                    std.log.err("registry GET {s}: HTTP {d}", .{ target, @intFromEnum(res.head.status) });
                    return error.RegistryError;
                },
            }
            try sink.head(res.head);
            var transfer_buf: [64 * 1024]u8 = undefined;
            const body = res.reader(&transfer_buf);
            var chunk: [64 * 1024]u8 = undefined;
            while (true) {
                const n = body.readSliceShort(&chunk) catch return res.bodyErr() orelse error.ReadFailed;
                if (n == 0) break;
                try sink.chunk(chunk[0..n]);
            }
            return;
        }
    }

    /// Handles `WWW-Authenticate: Bearer realm=…,service=…,scope=…` (token
    /// exchange) and `Basic` challenges.
    fn authenticate(self: *Client, challenge: []const u8) !void {
        if (std.ascii.startsWithIgnoreCase(challenge, "basic")) {
            const c = self.creds orelse return error.RegistryUnauthorized;
            return self.setAuth("Basic", try basic(self.gpa, c));
        }
        if (!std.ascii.startsWithIgnoreCase(challenge, "bearer ")) return error.RegistryUnauthorized;
        const params = challenge["bearer ".len..];
        const realm = param(params, "realm") orelse return error.RegistryUnauthorized;
        const service = param(params, "service") orelse "";
        var scope_buf: [512]u8 = undefined;
        const scope = param(params, "scope") orelse try std.fmt.bufPrint(&scope_buf, "repository:{s}:pull", .{self.ref.repository});

        var token_url_buf: [2048]u8 = undefined;
        const sep: u8 = if (std.mem.indexOfScalar(u8, realm, '?') != null) '&' else '?';
        const token_url = try std.fmt.bufPrint(&token_url_buf, "{s}{c}service={s}&scope={s}", .{ realm, sep, service, scope });

        var hdr_buf: [1]http.Header = undefined;
        var basic_value: ?[]u8 = null;
        defer if (basic_value) |b| self.gpa.free(b);
        if (self.creds) |c| if (c.username.len > 0) {
            const encoded = try basic(self.gpa, c);
            defer self.gpa.free(encoded);
            basic_value = try std.fmt.allocPrint(self.gpa, "Basic {s}", .{encoded});
            hdr_buf[0] = .{ .name = "Authorization", .value = basic_value.? };
        };

        var body: std.Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        const result = try self.http.fetch(.{
            .location = .{ .url = token_url },
            .extra_headers = if (basic_value != null) hdr_buf[0..1] else &.{},
            .response_writer = &body.writer,
        });
        if (result.status != .ok) return error.RegistryUnauthorized;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, body.written(), .{});
        defer parsed.deinit();
        const obj = ju.object(parsed.value) orelse return error.RegistryUnauthorized;
        const token = ju.str(obj.get("token")) orelse ju.str(obj.get("access_token")) orelse return error.RegistryUnauthorized;
        try self.setAuth("Bearer", try self.gpa.dupe(u8, token));
    }

    /// Takes ownership of `value`.
    fn setAuth(self: *Client, scheme: []const u8, value: []u8) !void {
        defer self.gpa.free(value);
        const next = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ scheme, value });
        errdefer self.gpa.free(next);
        self.auth_mutex.lockUncancelable(self.http.io);
        defer self.auth_mutex.unlock(self.http.io);
        try self.auth_history.append(self.gpa, next);
        self.auth = next;
    }
};

fn basic(gpa: std.mem.Allocator, c: Credentials) ![]u8 {
    const raw = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ c.username, c.password });
    defer gpa.free(raw);
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, raw);
    return out;
}

fn hostOf(url_str: []const u8) []const u8 {
    const start = (std.mem.indexOf(u8, url_str, "://") orelse return "") + 3;
    const end = std.mem.indexOfAnyPos(u8, url_str, start, "/?#") orelse url_str.len;
    return url_str[start..end];
}

fn header(head: http.Client.Response.Head, name: []const u8) ?[]const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// Value of `key="value"` (or unquoted) in an auth challenge parameter list.
fn param(params: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, params, ',');
    while (it.next()) |raw| {
        const kv = std.mem.trim(u8, raw, " ");
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, kv[0..eq], " "), key)) continue;
        return std.mem.trim(u8, kv[eq + 1 ..], "\" ");
    }
    return null;
}

const MemorySink = struct {
    alloc: std.mem.Allocator,
    limit: usize,
    body: std.ArrayList(u8) = .empty,
    content_type: ?[]const u8 = null,
    digest: ?[]const u8 = null,
    meta_buf: [256]u8 = undefined,

    fn head(self: *MemorySink, h: http.Client.Response.Head) !void {
        // Header strings are invalidated once the body is read; copy them.
        var used: usize = 0;
        if (h.content_type) |ct| {
            const n = @min(ct.len, 160);
            @memcpy(self.meta_buf[0..n], ct[0..n]);
            self.content_type = self.meta_buf[0..n];
            used = n;
        }
        if (header(h, "docker-content-digest")) |d| if (d.len == 71 and used + 71 <= self.meta_buf.len) {
            @memcpy(self.meta_buf[used .. used + 71], d);
            self.digest = self.meta_buf[used .. used + 71];
        };
    }

    fn chunk(self: *MemorySink, data: []const u8) !void {
        if (self.body.items.len + data.len > self.limit) return error.ManifestTooLarge;
        try self.body.appendSlice(self.alloc, data);
    }
};

fn BlobSink(comptime Progress: type) type {
    return struct {
        ingest: *content.Ingest,
        progress: Progress,

        fn head(_: *@This(), _: http.Client.Response.Head) !void {}

        fn chunk(self: *@This(), data: []const u8) !void {
            try self.ingest.write(data);
            if (Progress != void) self.progress.update(self.ingest.written);
        }
    };
}

test "auth challenge parsing" {
    const c = "realm=\"https://auth.docker.io/token\",service=\"registry.docker.io\",scope=\"repository:library/alpine:pull\"";
    try std.testing.expectEqualStrings("https://auth.docker.io/token", param(c, "realm").?);
    try std.testing.expectEqualStrings("registry.docker.io", param(c, "service").?);
    try std.testing.expectEqualStrings("repository:library/alpine:pull", param(c, "scope").?);
    try std.testing.expectEqual(null, param(c, "missing"));
    try std.testing.expectEqualStrings("cdn.example:443", hostOf("https://cdn.example:443/x?y"));

    const b = try basic(std.testing.allocator, .{ .username = "u", .password = "p" });
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("dTpw", b);
}

const std = @import("std");
const Daemon = @import("../daemon/daemon.zig").Daemon;
const router = @import("router.zig");
const request = @import("request.zig");
const Response = @import("response.zig").Response;
const Conn = @import("response.zig").Conn;

pub const Server = struct {
    daemon: *Daemon,
    allocator: std.mem.Allocator,
    socket_path: []const u8,

    pub fn init(daemon: *Daemon, socket_path: []const u8, allocator: std.mem.Allocator) Server {
        return .{ .daemon = daemon, .socket_path = socket_path, .allocator = allocator };
    }

    pub fn listen(self: *Server) !void {
        const io = self.daemon.config.io;
        var path_buf: [256:0]u8 = undefined;
        const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{self.socket_path});
        _ = std.os.linux.unlink(path_z.ptr);

        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        var server = try address.listen(io, .{ .kernel_backlog = std.Io.net.default_kernel_backlog });
        defer server.deinit(io);

        // root + the socket's group only, like /var/run/docker.sock.
        _ = std.os.linux.chmod(path_z.ptr, 0o660);
        std.log.info("API listening on {s}", .{self.socket_path});

        while (true) {
            // A failed accept (e.g. EMFILE) must not take the daemon down.
            const conn = server.accept(io) catch |err| {
                std.log.err("accept failed: {}", .{err});
                std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
                continue;
            };
            const ctx = self.allocator.create(ConnContext) catch {
                conn.close(io);
                continue;
            };
            ctx.* = .{ .daemon = self.daemon, .conn = conn, .allocator = self.allocator };
            const thread = std.Thread.spawn(.{}, handleConnection, .{ctx}) catch |err| {
                std.log.err("cannot spawn connection thread: {}", .{err});
                conn.close(io);
                self.allocator.destroy(ctx);
                continue;
            };
            thread.detach();
        }
    }
};

const ConnContext = struct {
    daemon: *Daemon,
    conn: std.Io.net.Stream,
    allocator: std.mem.Allocator,
};

const max_head_size = 64 * 1024;
const max_body_size: usize = 32 * 1024 * 1024;

/// Idle keep-alive connections are closed after this many requests to bound
/// per-connection memory held by long-lived clients.
const max_requests_per_conn = 1000;

fn handleConnection(ctx: *ConnContext) void {
    const io = ctx.daemon.config.io;
    defer ctx.allocator.destroy(ctx);
    defer ctx.conn.close(io);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    var read_buf: [max_head_size]u8 = undefined;
    var reader = ctx.conn.reader(io, &read_buf);
    var write_buf: [4096]u8 = undefined;
    var writer = ctx.conn.writer(io, &write_buf);
    const conn: Conn = .{ .reader = &reader.interface, .writer = &writer.interface };

    for (0..max_requests_per_conn) |_| {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();

        var meta: Meta = .{};
        const res = handleRequest(ctx.daemon, conn.reader, alloc, &meta) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => return,
            error.StreamTooLong => Response.errBody(431, "request header too large"),
            error.PayloadTooLarge => Response.errBody(413, "request body too large"),
            error.OutOfMemory => Response.internalError("out of memory"),
            else => Response.badRequest("malformed HTTP request"),
        };

        if (res.stream) |stream| {
            defer if (stream.cleanup) |c| c(stream.ctx);
            writeStreamHead(conn.writer, res, stream.hijack and meta.upgrade) catch return;
            stream.run(stream.ctx, conn) catch |err| switch (err) {
                error.WriteFailed, error.ReadFailed, error.EndOfStream => {},
                else => std.log.warn("stream ended: {}", .{err}),
            };
            conn.writer.flush() catch {};
            return; // streamed bodies are close-delimited
        }

        writeResponse(conn.writer, alloc, res, meta) catch return;
        if (!meta.keep_alive) return;
    }
}

const Meta = struct {
    keep_alive: bool = false,
    upgrade: bool = false,
    head: bool = false,
};

fn handleRequest(daemon: *Daemon, r: *std.Io.Reader, alloc: std.mem.Allocator, meta: *Meta) !Response {
    // Collect the head line by line; a line longer than the reader buffer
    // yields error.StreamTooLong (431).
    var head = std.ArrayList(u8).empty;
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        if (head.items.len + line.len > max_head_size) return error.StreamTooLong;
        if (std.mem.trimEnd(u8, line, "\r\n").len == 0) {
            if (head.items.len == 0) continue; // tolerate stray CRLF between requests
            break;
        }
        try head.appendSlice(alloc, line);
    }

    var req = try request.parseHead(head.items, alloc);
    req.body = try readBody(r, &req, alloc);
    meta.* = .{
        .keep_alive = req.keepAlive(),
        .upgrade = req.header("upgrade") != null,
        .head = std.mem.eql(u8, req.method, "HEAD"),
    };
    return router.dispatch(daemon, &req, alloc);
}

fn readBody(r: *std.Io.Reader, req: *const request.Request, alloc: std.mem.Allocator) ![]const u8 {
    if (req.header("transfer-encoding")) |te| {
        if (std.ascii.indexOfIgnoreCase(te, "chunked") != null) return readChunked(r, alloc);
    }
    const cl_str = req.header("content-length") orelse return "";
    const len = std.fmt.parseInt(usize, cl_str, 10) catch return error.InvalidRequest;
    if (len > max_body_size) return error.PayloadTooLarge;
    const body = try alloc.alloc(u8, len);
    try r.readSliceAll(body);
    return body;
}

fn readChunked(r: *std.Io.Reader, alloc: std.mem.Allocator) ![]const u8 {
    var body = std.ArrayList(u8).empty;
    while (true) {
        const size_line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
        const size_hex = std.mem.trim(u8, size_line[0 .. std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len], " ");
        const size = std.fmt.parseInt(usize, size_hex, 16) catch return error.InvalidRequest;
        if (size == 0) break;
        if (body.items.len + size > max_body_size) return error.PayloadTooLarge;
        try r.readSliceAll(try body.addManyAsSlice(alloc, size));
        _ = try r.takeDelimiterInclusive('\n'); // CRLF after chunk data
    }
    // Trailer section ends with an empty line.
    while (std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n").len != 0) {}
    return body.items;
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        304 => "Not Modified",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        else => "Unknown",
    };
}

fn writeResponse(w: *std.Io.Writer, alloc: std.mem.Allocator, res: Response, meta: Meta) !void {
    // Errors always use Docker's {"message": "..."} shape, properly escaped.
    const is_error = res.status >= 400;
    const body = if (is_error and !(res.body.len > 0 and res.body[0] == '{'))
        try std.json.Stringify.valueAlloc(alloc, .{ .message = res.body }, .{})
    else
        res.body;
    const content_type = if (is_error) "application/json" else res.content_type;
    const has_body = res.status != 204 and res.status != 304;

    try w.print("HTTP/1.1 {d} {s}\r\n", .{ res.status, statusText(res.status) });
    try writeCommonHeaders(w);
    if (has_body) try w.print("Content-Type: {s}\r\n", .{content_type});
    try w.print("Content-Length: {d}\r\n", .{if (has_body) body.len else 0});
    try w.writeAll(if (meta.keep_alive) "Connection: keep-alive\r\n\r\n" else "Connection: close\r\n\r\n");
    if (has_body and !meta.head) try w.writeAll(body);
    try w.flush();
}

fn writeStreamHead(w: *std.Io.Writer, res: Response, upgrade: bool) !void {
    if (upgrade) {
        try w.writeAll("HTTP/1.1 101 UPGRADED\r\n");
        try writeCommonHeaders(w);
        try w.print("Content-Type: {s}\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n", .{res.content_type});
    } else {
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ res.status, statusText(res.status) });
        try writeCommonHeaders(w);
        try w.print("Content-Type: {s}\r\nConnection: close\r\n\r\n", .{res.content_type});
    }
    // Clients (e.g. `docker run` waiting on /wait) rely on seeing headers early.
    try w.flush();
}

fn writeCommonHeaders(w: *std.Io.Writer) !void {
    try w.writeAll("Api-Version: 1.43\r\nDocker-Experimental: false\r\nOstype: linux\r\nServer: cratezig\r\n");
}

test "chunked body decoding" {
    var r = std.Io.Reader.fixed("5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("hello world", try readChunked(&r, arena.allocator()));
}

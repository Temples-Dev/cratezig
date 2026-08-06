const std = @import("std");
const Daemon = @import("../daemon/daemon.zig").Daemon;
const router = @import("router.zig");
const parseRequest = @import("request.zig").parseRequest;
const decodeChunked = @import("request.zig").decodeChunked;
const Response = @import("response.zig").Response;

pub const Server = struct {
    daemon: *Daemon,
    allocator: std.mem.Allocator,
    socket_path: []const u8,

    pub fn init(daemon: *Daemon, socket_path: []const u8, allocator: std.mem.Allocator) Server {
        return .{ .daemon = daemon, .socket_path = socket_path, .allocator = allocator };
    }

    pub fn listen(self: *Server) !void {
        var path_buf: [256:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&path_buf, "{s}", .{self.socket_path})) |pathZ| {
            _ = std.os.linux.unlink(pathZ.ptr);
        } else |_| {}

        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        var server = try address.listen(self.daemon.config.io, .{
            .kernel_backlog = std.Io.net.default_kernel_backlog,
        });
        defer server.deinit(self.daemon.config.io);

        _ = std.os.linux.chmod(&path_buf, 0o666);

        std.log.info("API listening on {s}", .{self.socket_path});

        while (true) {
            const conn = try server.accept(self.daemon.config.io);
            const ctx = try self.allocator.create(ConnContext);
            ctx.* = .{ .daemon = self.daemon, .conn = conn, .allocator = self.allocator };
            const thread = try std.Thread.spawn(.{}, handleConnection, .{ctx});
            thread.detach();
        }
    }
};

const ConnContext = struct {
    daemon: *Daemon,
    conn: std.Io.net.Stream,
    allocator: std.mem.Allocator,
};

fn handleConnection(ctx: *ConnContext) void {
    std.log.info("handleConnection: accepted connection", .{});
    defer ctx.allocator.destroy(ctx);
    defer ctx.conn.close(ctx.daemon.config.io);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: [8192]u8 = undefined;
    var read_buf: [1024]u8 = undefined;
    var reader = ctx.conn.reader(ctx.daemon.config.io, &read_buf);
    var slices = [_][]u8{&buf};
    const n = reader.interface.readVec(&slices) catch return;
    if (n == 0) return;
    const raw = buf[0..n];

    var req = parseRequest(raw, alloc) catch return;

    const te = req.headers.get("Transfer-Encoding") orelse req.headers.get("transfer-encoding");
    const is_chunked = if (te) |val| std.mem.indexOfPos(u8, val, 0, "chunked") != null else false;
    const is_build = std.mem.indexOf(u8, req.path, "/build") != null;
    const cl = req.headers.get("Content-Length") orelse req.headers.get("content-length");
    if (cl) |cl_str| {
        if (std.fmt.parseInt(usize, cl_str, 10)) |content_len| {
            if (req.body.len < content_len) {
                const full_body = alloc.alloc(u8, content_len) catch return;
                @memcpy(full_body[0..req.body.len], req.body);

                var read_so_far = req.body.len;
                while (read_so_far < content_len) {
                    var chunk: [8192]u8 = undefined;
                    var chunk_slices = [_][]u8{&chunk};
                    const bytes_read = reader.interface.readVec(&chunk_slices) catch break;
                    if (bytes_read == 0) break;
                    const to_copy = @min(bytes_read, content_len - read_so_far);
                    @memcpy(full_body[read_so_far .. read_so_far + to_copy], chunk[0..to_copy]);
                    read_so_far += to_copy;
                }
                req.body = full_body[0..read_so_far];
            }
        } else |_| {}
    } else if (is_chunked or is_build) {
        var body_list = std.ArrayList(u8).empty;
        defer body_list.deinit(alloc);
        if (req.body.len > 0) {
            body_list.appendSlice(alloc, req.body) catch return;
        }

        while (true) {
            var read_chunk: [8192]u8 = undefined;
            var chunk_slices = [_][]u8{&read_chunk};
            const bytes_read = reader.interface.readVec(&chunk_slices) catch break;
            if (bytes_read == 0) break;
            body_list.appendSlice(alloc, read_chunk[0..bytes_read]) catch break;
            if (std.mem.endsWith(u8, body_list.items, "0\r\n\r\n")) break;
        }
        const full_raw = body_list.toOwnedSlice(alloc) catch return;
        if (is_chunked) {
            req.body = decodeChunked(alloc, full_raw) catch full_raw;
        } else {
            req.body = full_raw;
        }
    }

    const res = router.dispatch(ctx.daemon, &req, alloc);

    writeResponse(ctx.daemon.config.io, ctx.conn, res) catch |err| {
        std.log.err("handleConnection: write error: {}", .{err});
    };
    std.log.info("handleConnection: done response", .{});
}

fn writeResponse(io: std.Io, stream: std.Io.net.Stream, res: Response) !void {
    const status_text = switch (res.status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        304 => "Not Modified",
        400 => "Bad Request",
        404 => "Not Found",
        409 => "Conflict",
        500 => "Internal Server Error",
        else => "OK",
    };
    var write_buf: [2048]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.print("HTTP/1.1 {d} {s}\r\n", .{ res.status, status_text });
    try writer.interface.print("Content-Type: {s}\r\n", .{ res.content_type });
    try writer.interface.print("Content-Length: {d}\r\n", .{ res.body.len });
    try writer.interface.print("Connection: close\r\n\r\n", .{});
    if (res.body.len > 0) {
        try writer.interface.writeAll(res.body);
    }
    try writer.interface.flush();
}

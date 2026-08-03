const std = @import("std");
const Daemon = @import("../daemon/daemon.zig").Daemon;
const router = @import("router.zig");
const parseRequest = @import("request.zig").parseRequest;
const Response = @import("response.zig").Response;

pub const Server = struct {
    daemon: *Daemon,
    allocator: std.mem.Allocator,
    socket_path: []const u8,

    pub fn init(daemon: *Daemon, socket_path: []const u8, allocator: std.mem.Allocator) Server {
        return .{ .daemon = daemon, .socket_path = socket_path, .allocator = allocator };
    }

    pub fn listen(self: *Server) !void {
        // Remove old socket file if it exists
        std.Io.Dir.deleteFileAbsolute(self.daemon.config.io, self.socket_path) catch {};

        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        var server = try address.listen(self.daemon.config.io, .{
            .kernel_backlog = std.Io.net.default_kernel_backlog,
        });
        defer server.deinit(self.daemon.config.io);

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
    defer ctx.allocator.destroy(ctx);
    defer ctx.conn.close(ctx.daemon.config.io);

    // Read the HTTP request
    var buf: [8192]u8 = undefined;
    var read_buf: [1024]u8 = undefined;
    var reader = ctx.conn.reader(ctx.daemon.config.io, &read_buf);
    const n = reader.interface.readSliceShort(&buf) catch return;
    if (n == 0) return;
    const raw = buf[0..n];

    var req = parseRequest(raw, ctx.allocator) catch return;
    defer req.deinit();

    var res = router.dispatch(ctx.daemon, &req, ctx.allocator);
    defer res.deinit();

    writeResponse(ctx.daemon.config.io, ctx.conn, res) catch {};
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
}

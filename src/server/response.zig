const std = @import("std");

/// The raw connection, handed to streaming handlers after headers are sent.
pub const Conn = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
};

/// A response whose body is produced incrementally (logs -f, events, wait)
/// or that takes over the connection (attach, exec). `ctx` must live in the
/// request arena.
pub const Stream = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, conn: Conn) anyerror!void,
    /// Always called once the response is done, even if `run` never ran
    /// (e.g. the client vanished before headers were written).
    cleanup: ?*const fn (ctx: *anyopaque) void = null,
    /// Switch protocols (101 UPGRADED) when the client asked for it.
    hijack: bool = false,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "application/json",
    stream: ?Stream = null,

    pub fn streaming(content_type: []const u8, s: Stream) Response {
        return .{ .status = 200, .body = "", .content_type = content_type, .stream = s };
    }

    pub fn ok(body: []const u8) Response {
        return .{ .status = 200, .body = body };
    }
    pub fn created(body: []const u8) Response {
        return .{ .status = 201, .body = body };
    }
    pub fn noContent() Response {
        return .{ .status = 204, .body = "" };
    }
    pub fn notModified() Response {
        return .{ .status = 304, .body = "" };
    }
    pub fn badRequest(msg: []const u8) Response {
        return errBody(400, msg);
    }
    pub fn payloadTooLarge(msg: []const u8) Response {
        return errBody(413, msg);
    }
    pub fn notFound(msg: []const u8) Response {
        return errBody(404, msg);
    }
    pub fn conflict(msg: []const u8) Response {
        return errBody(409, msg);
    }
    pub fn internalError(msg: []const u8) Response {
        return errBody(500, msg);
    }
    pub fn notImplemented(msg: []const u8) Response {
        return errBody(501, msg);
    }

    pub fn fromError(err: anyerror) Response {
        const code: u16 = switch (err) {
            error.ContainerNotFound,
            error.ImageNotFound,
            error.NetworkNotFound,
            error.VolumeNotFound,
            error.ExecNotFound,
            => 404,
            error.ContainerAlreadyRunning => 304,
            error.ContainerNameInUse,
            error.ContainerBeingRemoved,
            error.ContainerNotRunning,
            error.ContainerAlreadyPaused,
            error.ContainerNotPaused,
            error.NetworkAlreadyExists,
            error.NetworkHasEndpoints,
            error.ImageInUse,
            error.VolumeInUse,
            => 409,
            error.InvalidParameter,
            error.NoCommandSpecified,
            error.UserNotFound,
            error.GroupNotFound,
            => 400,
            error.Forbidden => 403,
            error.NotImplemented => 501,
            else => 500,
        };
        return errBody(code, @errorName(err));
    }

    /// The server wraps non-JSON error bodies as {"message": ...}.
    pub fn errBody(status: u16, msg: []const u8) Response {
        return .{ .status = status, .body = msg };
    }

    pub fn deinit(self: *Response) void {
        _ = self;
    }
};

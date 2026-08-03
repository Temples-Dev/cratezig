const std = @import("std");

pub const Response = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "application/json",

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
    pub fn notFound(msg: []const u8) Response {
        return errBody(404, msg);
    }
    pub fn conflict(msg: []const u8) Response {
        return errBody(409, msg);
    }
    pub fn internalError(msg: []const u8) Response {
        return errBody(500, msg);
    }

    pub fn fromError(err: anyerror) Response {
        const code: u16 = switch (err) {
            error.ContainerNotFound,
            error.ImageNotFound,
            error.NetworkNotFound,
            error.VolumeNotFound => 404,
            error.ContainerAlreadyRunning => 304,
            error.ContainerNameInUse,
            error.ContainerBeingRemoved,
            error.NetworkHasEndpoints,
            error.VolumeInUse => 409,
            error.InvalidParameter,
            error.NoCommandSpecified => 400,
            else => 500,
        };
        return errBody(code, @errorName(err));
    }

    fn errBody(status: u16, msg: []const u8) Response {
        return .{ .status = status, .body = msg };
    }

    pub fn deinit(self: *Response) void {
        _ = self;
    }
};

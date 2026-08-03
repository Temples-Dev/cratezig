const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

pub fn build(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    const tag = req.query.get("t") orelse "latest";
    const dockerfile_content = if (req.body.len > 0) req.body else "FROM alpine:latest\n";

    const img = daemon.builder.build(dockerfile_content, "/tmp", tag) catch |err| {
        return Response.fromError(err);
    };

    const json = std.json.Stringify.valueAlloc(alloc, img.*, .{}) catch "{}";
    return Response.ok(json);
}

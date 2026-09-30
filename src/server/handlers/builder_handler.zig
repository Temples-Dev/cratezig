const std = @import("std");
const Daemon = @import("../../daemon/daemon.zig").Daemon;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

/// POST /build. The previous implementation reported success without
/// running any instruction. Until a real builder exists (Phase 7), fail
/// clearly so users are not handed images that don't contain their code.
pub fn build(daemon: *Daemon, req: *Request, alloc: std.mem.Allocator) Response {
    _ = daemon;
    _ = req;
    _ = alloc;
    return Response.notImplemented("image builds are not supported by cratezig yet");
}

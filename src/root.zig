//! By convention, root.zig is the root source file when making a package.

test "compilation check" {
    _ = @import("daemon/daemon.zig");
    _ = @import("daemon/create.zig");
    _ = @import("daemon/start.zig");
    _ = @import("daemon/stop.zig");
    _ = @import("daemon/monitor.zig");
    _ = @import("server/server.zig");
    _ = @import("server/router.zig");
    _ = @import("server/request.zig");
    _ = @import("server/response.zig");
    _ = @import("server/handlers/container.zig");
    _ = @import("server/handlers/images.zig");
    _ = @import("server/handlers/networks.zig");
    _ = @import("server/handlers/volumes.zig");
    _ = @import("server/handlers/system.zig");
    _ = @import("builder/spec.zig");
    _ = @import("builder/cache.zig");
    _ = @import("builder/context.zig");
    _ = @import("builder/builder.zig");
}

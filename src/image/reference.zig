//! Docker image references: "alpine", "user/app:1", "ghcr.io/o/app@sha256:…".
const std = @import("std");

pub const docker_hub = "docker.io";
/// The API endpoint behind docker.io.
pub const docker_hub_api = "registry-1.docker.io";

pub const Reference = struct {
    /// Registry host[:port], e.g. "docker.io", "ghcr.io", "localhost:5000".
    registry: []const u8,
    /// Repository path, e.g. "library/alpine".
    repository: []const u8,
    tag: []const u8 = "latest",
    /// "sha256:<hex>" when pinned by digest.
    digest: ?[]const u8 = null,
    /// "registry/repository", or just the repository on Docker Hub.
    full: []const u8 = "",

    /// Host to talk HTTPS to.
    pub fn apiHost(self: Reference) []const u8 {
        return if (std.mem.eql(u8, self.registry, docker_hub)) docker_hub_api else self.registry;
    }

    /// The tag or digest to request from the registry.
    pub fn manifestRef(self: Reference) []const u8 {
        return self.digest orelse self.tag;
    }

    /// Docker's short form, as shown in `docker images`: "alpine:latest",
    /// "user/app:1", "ghcr.io/o/app:2".
    pub fn familiarTag(self: Reference, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}:{s}", .{ self.familiarName(), self.tag }) catch error.NameTooLong;
    }

    pub fn familiarName(self: Reference) []const u8 {
        if (!std.mem.eql(u8, self.registry, docker_hub)) return self.full;
        if (std.mem.startsWith(u8, self.repository, "library/")) return self.repository["library/".len..];
        return self.repository;
    }
};

pub const ParseError = error{ InvalidReference, OutOfMemory };

/// Parses and normalizes a reference. Returned slices point into `raw`,
/// except the Docker Hub "library/" prefix, which is allocated with `alloc`.
pub fn parse(alloc: std.mem.Allocator, raw: []const u8) ParseError!Reference {
    if (raw.len == 0 or raw.len > 255) return error.InvalidReference;
    var name = raw;
    var ref: Reference = .{ .registry = docker_hub, .repository = "" };

    if (std.mem.indexOfScalar(u8, name, '@')) |at| {
        const digest = name[at + 1 ..];
        if (!validDigest(digest)) return error.InvalidReference;
        ref.digest = digest;
        name = name[0..at];
    }
    // A ':' after the last '/' is a tag; before it, a registry port.
    const last_slash = std.mem.lastIndexOfScalar(u8, name, '/');
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| {
        if (last_slash == null or colon > last_slash.?) {
            ref.tag = name[colon + 1 ..];
            if (!validTag(ref.tag)) return error.InvalidReference;
            name = name[0..colon];
        }
    }

    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        const first = name[0..slash];
        if (std.mem.indexOfAny(u8, first, ".:") != null or std.mem.eql(u8, first, "localhost")) {
            ref.registry = first;
            name = name[slash + 1 ..];
        }
    }
    if (std.mem.eql(u8, ref.registry, "index.docker.io")) ref.registry = docker_hub;
    if (!validRepository(name)) return error.InvalidReference;

    if (std.mem.eql(u8, ref.registry, docker_hub) and std.mem.indexOfScalar(u8, name, '/') == null) {
        ref.repository = try std.fmt.allocPrint(alloc, "library/{s}", .{name});
    } else {
        ref.repository = name;
    }
    ref.full = if (std.mem.eql(u8, ref.registry, docker_hub))
        ref.repository
    else
        try std.fmt.allocPrint(alloc, "{s}/{s}", .{ ref.registry, ref.repository });
    return ref;
}

fn validTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 128) return false;
    if (!(std.ascii.isAlphanumeric(tag[0]) or tag[0] == '_')) return false;
    for (tag) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return false;
    return true;
}

fn validRepository(repo: []const u8) bool {
    if (repo.len == 0) return false;
    var parts = std.mem.splitScalar(u8, repo, '/');
    while (parts.next()) |p| {
        if (p.len == 0 or !std.ascii.isAlphanumeric(p[0]) or !std.ascii.isAlphanumeric(p[p.len - 1])) return false;
        for (p) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return true;
}

pub fn validDigest(d: []const u8) bool {
    if (!std.mem.startsWith(u8, d, "sha256:") or d.len != 7 + 64) return false;
    for (d[7..]) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}

test "normalizes docker hub names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;

    const r1 = try parse(a, "alpine");
    try std.testing.expectEqualStrings("registry-1.docker.io", r1.apiHost());
    try std.testing.expectEqualStrings("library/alpine", r1.repository);
    try std.testing.expectEqualStrings("alpine:latest", try r1.familiarTag(&buf));

    const r2 = try parse(a, "user/app:1.2");
    try std.testing.expectEqualStrings("user/app", r2.repository);
    try std.testing.expectEqualStrings("user/app:1.2", try r2.familiarTag(&buf));

    const r3 = try parse(a, "localhost:5000/team/app");
    try std.testing.expectEqualStrings("localhost:5000", r3.registry);
    try std.testing.expectEqualStrings("localhost:5000/team/app:latest", try r3.familiarTag(&buf));

    const d = "sha256:" ++ "a" ** 64;
    const r4 = try parse(a, "ghcr.io/o/app@" ++ d);
    try std.testing.expectEqualStrings(d, r4.manifestRef());

    try std.testing.expectError(error.InvalidReference, parse(a, "UPPER"));
    try std.testing.expectError(error.InvalidReference, parse(a, "app@sha256:short"));
    try std.testing.expectError(error.InvalidReference, parse(a, "app:bad tag"));
}

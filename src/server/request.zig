const std = @import("std");

/// Path parameter store backed by a small inline array.
/// Routes have at most 2 path parameters ({name}, {id}, etc.) so 8 slots is
/// more than enough. Zero heap allocation — stored directly in the Request.
pub const PathParams = struct {
    entries: [8]struct { key: []const u8, val: []const u8 } = undefined,
    len: u8 = 0,

    pub fn init(_: std.mem.Allocator) PathParams {
        return .{};
    }

    pub fn deinit(_: *PathParams) void {}

    pub fn put(self: *PathParams, key: []const u8, val: []const u8) !void {
        if (self.len >= 8) return error.TooManyParams;
        self.entries[self.len] = .{ .key = key, .val = val };
        self.len += 1;
    }

    pub fn get(self: *const PathParams, key: []const u8) ?[]const u8 {
        // Linear scan over ≤8 items: faster than a HashMap for small N.
        for (self.entries[0..self.len]) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.val;
        }
        return null;
    }
};

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: std.StringHashMap([]const u8),
    params: PathParams,
    body: []const u8,
    headers: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Request {
        return .{
            .method = "",
            .path = "",
            .query = std.StringHashMap([]const u8).init(allocator),
            .params = PathParams{},
            .body = "",
            .headers = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        self.query.deinit();
        self.headers.deinit();
    }
};

pub fn parseRequest(raw: []const u8, allocator: std.mem.Allocator) !Request {
    var req = Request.init(allocator);
    errdefer req.deinit();

    const double_line_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse std.mem.indexOf(u8, raw, "\n\n") orelse raw.len;
    const header_part = raw[0..double_line_end];
    const body_part = if (double_line_end + 4 <= raw.len) raw[double_line_end + 4..] else if (double_line_end + 2 <= raw.len) raw[double_line_end + 2 ..] else &.{};
    req.body = body_part;

    var line_it = std.mem.splitAny(u8, header_part, "\r\n");
    const first_line = line_it.next() orelse return error.InvalidRequest;

    var first_line_parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = first_line_parts.next() orelse return error.InvalidRequest;
    const full_path = first_line_parts.next() orelse return error.InvalidRequest;

    req.method = method;

    // Parse path and query
    const question_mark = std.mem.indexOfScalar(u8, full_path, '?');
    if (question_mark) |qm| {
        req.path = full_path[0..qm];
        const query_str = full_path[qm + 1..];
        var query_it = std.mem.splitScalar(u8, query_str, '&');
        while (query_it.next()) |param| {
            if (param.len == 0) continue;
            var kv = std.mem.splitScalar(u8, param, '=');
            const k = kv.next() orelse continue;
            const v = kv.next() orelse "";
            try req.query.put(k, v);
        }
    } else {
        req.path = full_path;
    }

    // Parse headers
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t\r\n");
        const val = std.mem.trim(u8, line[colon + 1..], " \t\r\n");
        try req.headers.put(name, val);
    }

    return req;
}

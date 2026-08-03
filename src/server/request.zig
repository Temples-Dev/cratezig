const std = @import("std");

pub const PathParams = struct {
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) PathParams {
        return .{
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *PathParams) void {
        self.map.deinit();
    }

    pub fn put(self: *PathParams, key: []const u8, value: []const u8) !void {
        try self.map.put(key, value);
    }

    pub fn get(self: *const PathParams, key: []const u8) ?[]const u8 {
        return self.map.get(key);
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
            .params = PathParams.init(allocator),
            .body = "",
            .headers = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        self.query.deinit();
        self.params.deinit();
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

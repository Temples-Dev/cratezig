const std = @import("std");

pub const PathParams = struct {
    entries: [8]struct { key: []const u8, val: []const u8 } = undefined,
    len: u8 = 0,

    pub fn put(self: *PathParams, key: []const u8, val: []const u8) !void {
        if (self.len >= 8) return error.TooManyParams;
        self.entries[self.len] = .{ .key = key, .val = val };
        self.len += 1;
    }

    pub fn get(self: *const PathParams, key: []const u8) ?[]const u8 {
        for (self.entries[0..self.len]) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.val;
        }
        return null;
    }
};

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    /// Percent-decoded query parameters.
    query: std.StringHashMap([]const u8),
    params: PathParams,
    body: []const u8,
    /// Header names are lower-cased; look them up in lower case.
    headers: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Request {
        return .{
            .method = "",
            .path = "",
            .query = .init(allocator),
            .params = .{},
            .body = "",
            .headers = .init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        self.query.deinit();
        self.headers.deinit();
    }

    /// Go's strconv.ParseBool, which the Docker API uses: "1", "t", "true"...
    pub fn queryBool(self: *const Request, key: []const u8) bool {
        const v = self.query.get(key) orelse return false;
        for ([_][]const u8{ "1", "t", "T", "true", "TRUE", "True" }) |t| {
            if (std.mem.eql(u8, v, t)) return true;
        }
        return false;
    }

    pub fn header(self: *const Request, lower_name: []const u8) ?[]const u8 {
        return self.headers.get(lower_name);
    }
};

/// Parses the request line and headers (everything before the blank line).
/// Strings are allocated with `allocator` (the request arena).
pub fn parseHead(head: []const u8, allocator: std.mem.Allocator) !Request {
    var req = Request.init(allocator);
    errdefer req.deinit();

    var lines = std.mem.splitScalar(u8, head, '\n');
    const first_line = std.mem.trimEnd(u8, lines.next() orelse return error.InvalidRequest, "\r");
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    req.method = parts.next() orelse return error.InvalidRequest;
    const target = parts.next() orelse return error.InvalidRequest;
    if (req.method.len == 0 or target.len == 0 or target[0] != '/') return error.InvalidRequest;

    if (std.mem.indexOfScalar(u8, target, '?')) |qm| {
        req.path = target[0..qm];
        var query_it = std.mem.splitScalar(u8, target[qm + 1 ..], '&');
        while (query_it.next()) |param| {
            if (param.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, param, '=');
            const k = try percentDecode(allocator, param[0 .. eq orelse param.len]);
            const v = if (eq) |e| try percentDecode(allocator, param[e + 1 ..]) else "";
            try req.query.put(k, v);
        }
    } else {
        req.path = target;
    }

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidRequest;
        const name = try std.ascii.allocLowerString(allocator, std.mem.trim(u8, line[0..colon], " \t"));
        try req.headers.put(name, std.mem.trim(u8, line[colon + 1 ..], " \t"));
    }
    return req;
}

/// Decodes %XX escapes and '+' (form encoding, as Go's url.Values emits).
pub fn percentDecode(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "%+") == null) return s;
    const out = try allocator.alloc(u8, s.len);
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = if (s[i] == '+') ' ' else s[i];
        i += 1;
    }
    return out[0..n];
}

test "parseHead lower-cases headers and decodes query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseHead("POST /v1.43/containers/create?name=web&filters=%7B%22a%22%3A1%7D&x=a+b HTTP/1.1\r\nContent-Type: application/json\r\nHost: docker\r\n", arena.allocator());
    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/v1.43/containers/create", req.path);
    try std.testing.expectEqualStrings("web", req.query.get("name").?);
    try std.testing.expectEqualStrings("{\"a\":1}", req.query.get("filters").?);
    try std.testing.expectEqualStrings("a b", req.query.get("x").?);
    try std.testing.expectEqualStrings("application/json", req.header("content-type").?);
}

test "parseHead rejects malformed request lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidRequest, parseHead("GARBAGE", arena.allocator()));
    try std.testing.expectError(error.InvalidRequest, parseHead("GET /x HTTP/1.1\r\nno-colon-header\r\n", arena.allocator()));
}

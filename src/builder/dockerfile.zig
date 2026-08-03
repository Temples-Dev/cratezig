const std = @import("std");

pub const InstructionKind = enum {
    from,
    run,
    copy,
    add,
    env,
    workdir,
    expose,
    cmd,
    entrypoint,
    arg,
};

pub const Instruction = struct {
    kind: InstructionKind,
    raw: []const u8,
    args: [][]const u8,

    pub fn deinit(self: *Instruction, allocator: std.mem.Allocator) void {
        for (self.args) |a| allocator.free(a);
        allocator.free(self.args);
        allocator.free(self.raw);
    }
};

pub const Dockerfile = struct {
    instructions: []Instruction,
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Dockerfile {
        var list = std.ArrayList(Instruction).empty;
        errdefer {
            for (list.items) |*inst| inst.deinit(allocator);
            list.deinit(allocator);
        }

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, " \r\t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            const space_idx = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
            const verb = trimmed[0..space_idx];
            const rest = if (space_idx < trimmed.len) std.mem.trim(u8, trimmed[space_idx + 1 ..], " \t") else "";

            const kind = parseKind(verb) orelse continue;
            const args = try parseArgs(allocator, rest);

            try list.append(allocator, .{
                .kind = kind,
                .raw = try allocator.dupe(u8, trimmed),
                .args = args,
            });
        }

        return .{
            .instructions = try list.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Dockerfile) void {
        for (self.instructions) |*inst| inst.deinit(self.allocator);
        self.allocator.free(self.instructions);
    }
};

fn parseKind(verb: []const u8) ?InstructionKind {
    if (std.ascii.eqlIgnoreCase(verb, "FROM")) return .from;
    if (std.ascii.eqlIgnoreCase(verb, "RUN")) return .run;
    if (std.ascii.eqlIgnoreCase(verb, "COPY")) return .copy;
    if (std.ascii.eqlIgnoreCase(verb, "ADD")) return .add;
    if (std.ascii.eqlIgnoreCase(verb, "ENV")) return .env;
    if (std.ascii.eqlIgnoreCase(verb, "WORKDIR")) return .workdir;
    if (std.ascii.eqlIgnoreCase(verb, "EXPOSE")) return .expose;
    if (std.ascii.eqlIgnoreCase(verb, "CMD")) return .cmd;
    if (std.ascii.eqlIgnoreCase(verb, "ENTRYPOINT")) return .entrypoint;
    if (std.ascii.eqlIgnoreCase(verb, "ARG")) return .arg;
    return null;
}

fn parseArgs(allocator: std.mem.Allocator, rest: []const u8) ![][]const u8 {
    if (rest.len == 0) return try allocator.alloc([]const u8, 0);

    var tokens = std.ArrayList([]const u8).empty;
    errdefer {
        for (tokens.items) |t| allocator.free(t);
        tokens.deinit(allocator);
    }

    var it = std.mem.tokenizeAny(u8, rest, " \t");
    while (it.next()) |tok| {
        try tokens.append(allocator, try allocator.dupe(u8, tok));
    }

    return try tokens.toOwnedSlice(allocator);
}

test "parse simple Dockerfile" {
    const alloc = std.testing.allocator;
    const content =
        \\FROM alpine:latest
        \\ENV PORT=8080
        \\WORKDIR /app
        \\COPY . .
        \\RUN echo build
        \\CMD ["./app"]
    ;

    var df = try Dockerfile.parse(alloc, content);
    defer df.deinit();

    try std.testing.expectEqual(@as(usize, 6), df.instructions.len);
    try std.testing.expectEqual(InstructionKind.from, df.instructions[0].kind);
    try std.testing.expectEqual(InstructionKind.env, df.instructions[1].kind);
    try std.testing.expectEqual(InstructionKind.workdir, df.instructions[2].kind);
    try std.testing.expectEqual(InstructionKind.copy, df.instructions[3].kind);
    try std.testing.expectEqual(InstructionKind.run, df.instructions[4].kind);
    try std.testing.expectEqual(InstructionKind.cmd, df.instructions[5].kind);
}

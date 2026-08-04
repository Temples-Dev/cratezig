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
    label,
    user,
    healthcheck,
    volume,
    shell,
};

pub const Instruction = struct {
    kind: InstructionKind,
    raw: []const u8,
    args: [][]const u8,
    stage_name: ?[]const u8 = null,
    from_stage: ?[]const u8 = null,

    pub fn deinit(self: *Instruction, allocator: std.mem.Allocator) void {
        if (self.stage_name) |sn| allocator.free(sn);
        if (self.from_stage) |fs| allocator.free(fs);
        for (self.args) |a| allocator.free(a);
        allocator.free(self.args);
        allocator.free(self.raw);
    }
};

pub const Dockerfile = struct {
    instructions: []Instruction,
    stage_index_map: std.StringHashMap(u16),
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Dockerfile {
        var list = std.ArrayList(Instruction).empty;
        var stage_map = std.StringHashMap(u16).init(allocator);
        var stage_counter: u16 = 0;

        errdefer {
            for (list.items) |*inst| inst.deinit(allocator);
            list.deinit(allocator);
            var it = stage_map.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            stage_map.deinit();
        }

        var multiline_buf = std.ArrayList(u8).empty;
        defer multiline_buf.deinit(allocator);

        var heredoc_delimiter: ?[]const u8 = null;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, " \r\t");
            if (trimmed.len == 0 or (multiline_buf.items.len == 0 and trimmed[0] == '#')) continue;

            if (heredoc_delimiter) |delim| {
                if (std.mem.eql(u8, trimmed, delim)) {
                    heredoc_delimiter = null;
                } else {
                    if (multiline_buf.items.len > 0) try multiline_buf.append(allocator, '\n');
                    try multiline_buf.appendSlice(allocator, raw_line);
                    continue;
                }
            } else if (std.mem.indexOf(u8, trimmed, "<<") != null) {
                if (std.mem.indexOf(u8, trimmed, "<<EOF")) |_| {
                    heredoc_delimiter = "EOF";
                    try multiline_buf.appendSlice(allocator, trimmed);
                    continue;
                }
            }

            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\\') {
                const part = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t");
                if (multiline_buf.items.len > 0) try multiline_buf.append(allocator, ' ');
                try multiline_buf.appendSlice(allocator, part);
                continue;
            }

            var line_to_parse = trimmed;
            if (multiline_buf.items.len > 0) {
                try multiline_buf.append(allocator, ' ');
                try multiline_buf.appendSlice(allocator, trimmed);
                line_to_parse = multiline_buf.items;
            }

            defer multiline_buf.clearRetainingCapacity();

            const space_idx = std.mem.indexOfScalar(u8, line_to_parse, ' ') orelse line_to_parse.len;
            const verb = line_to_parse[0..space_idx];
            const rest = if (space_idx < line_to_parse.len) std.mem.trim(u8, line_to_parse[space_idx + 1 ..], " \t") else "";

            const kind = parseKind(verb) orelse continue;
            const args = try parseArgs(allocator, rest);

            var stage_name: ?[]const u8 = null;
            var from_stage: ?[]const u8 = null;

            if (kind == .from) {
                for (args, 0..) |arg, i| {
                    if (std.ascii.eqlIgnoreCase(arg, "AS") and i + 1 < args.len) {
                        stage_name = try allocator.dupe(u8, args[i + 1]);
                        try stage_map.put(try allocator.dupe(u8, stage_name.?), stage_counter);
                        break;
                    }
                }
                stage_counter += 1;
            } else if (kind == .copy) {
                for (args) |arg| {
                    if (std.mem.startsWith(u8, arg, "--from=")) {
                        from_stage = try allocator.dupe(u8, arg["--from=".len..]);
                        break;
                    }
                }
            }

            try list.append(allocator, .{
                .kind = kind,
                .raw = try allocator.dupe(u8, line_to_parse),
                .args = args,
                .stage_name = stage_name,
                .from_stage = from_stage,
            });
        }

        return .{
            .instructions = try list.toOwnedSlice(allocator),
            .stage_index_map = stage_map,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Dockerfile) void {
        for (self.instructions) |*inst| inst.deinit(self.allocator);
        self.allocator.free(self.instructions);
        var it = self.stage_index_map.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.stage_index_map.deinit();
    }

    pub fn getStageIndex(self: Dockerfile, name: []const u8) ?u16 {
        return self.stage_index_map.get(name);
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
    if (std.ascii.eqlIgnoreCase(verb, "LABEL")) return .label;
    if (std.ascii.eqlIgnoreCase(verb, "USER")) return .user;
    if (std.ascii.eqlIgnoreCase(verb, "HEALTHCHECK")) return .healthcheck;
    if (std.ascii.eqlIgnoreCase(verb, "VOLUME")) return .volume;
    if (std.ascii.eqlIgnoreCase(verb, "SHELL")) return .shell;
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

test "parse multi-stage dockerfile with AS and COPY --from" {
    const alloc = std.testing.allocator;
    const df_content =
        \\FROM golang:1.21 AS builder
        \\WORKDIR /app
        \\RUN <<EOF
        \\echo building app
        \\EOF
        \\FROM alpine:latest
        \\COPY --from=builder /app/bin /bin/app
    ;

    var df = try Dockerfile.parse(alloc, df_content);
    defer df.deinit();

    try std.testing.expect(df.instructions.len == 5);
    try std.testing.expectEqualStrings("builder", df.instructions[0].stage_name.?);
    try std.testing.expectEqualStrings("builder", df.instructions[4].from_stage.?);
}

test "stage index map resolution" {
    const alloc = std.testing.allocator;
    const df_content =
        \\FROM golang:1.21 AS builder
        \\RUN echo build
        \\FROM alpine:latest AS final
        \\COPY --from=builder /app /app
    ;

    var df = try Dockerfile.parse(alloc, df_content);
    defer df.deinit();

    try std.testing.expectEqual(@as(?u16, 0), df.getStageIndex("builder"));
    try std.testing.expectEqual(@as(?u16, 1), df.getStageIndex("final"));
    try std.testing.expectEqual(@as(?u16, null), df.getStageIndex("missing"));
}

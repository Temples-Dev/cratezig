const std = @import("std");

pub const Volume = struct {
    name: []const u8,
    driver: []const u8 = "local",
    mountpoint: []const u8,
    created: i64,
    labels: std.StringHashMap([]const u8),
    options: std.StringHashMap([]const u8),
    scope: []const u8 = "local",

    pub fn jsonStringify(self: Volume, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Name");
        try jws.write(self.name);
        try jws.objectField("Driver");
        try jws.write(self.driver);
        try jws.objectField("Mountpoint");
        try jws.write(self.mountpoint);
        try jws.objectField("CreatedAt");
        try jws.write(self.created);
        
        try jws.objectField("Labels");
        try jws.beginObject();
        var label_it = self.labels.iterator();
        while (label_it.next()) |entry| {
            try jws.objectField(entry.key_ptr.*);
            try jws.write(entry.value_ptr.*);
        }
        try jws.endObject();

        try jws.objectField("Options");
        try jws.beginObject();
        var opts_it = self.options.iterator();
        while (opts_it.next()) |entry| {
            try jws.objectField(entry.key_ptr.*);
            try jws.write(entry.value_ptr.*);
        }
        try jws.endObject();

        try jws.objectField("Scope");
        try jws.write(self.scope);
        try jws.endObject();
    }
};

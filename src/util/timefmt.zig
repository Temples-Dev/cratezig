//! RFC 3339 timestamps, the format the Docker API uses for dates.
const std = @import("std");

/// Formats nanoseconds since the Unix epoch as "YYYY-MM-DDTHH:MM:SS.nnnnnnnnnZ".
/// Zero (unset) renders as Docker's zero time.
pub fn rfc3339(buf: *[40]u8, epoch_ns: i128) []const u8 {
    if (epoch_ns <= 0) return "0001-01-01T00:00:00Z";
    const secs: u64 = @intCast(@divFloor(epoch_ns, std.time.ns_per_s));
    const nanos: u64 = @intCast(@mod(epoch_ns, std.time.ns_per_s));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z", .{
        yd.year,                md.month.numeric(),       md.day_index + 1,
        ds.getHoursIntoDay(),   ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        nanos,
    }) catch unreachable;
}

/// Parses the UTC form produced by `rfc3339` (fractional seconds optional).
pub fn parseRfc3339(s: []const u8) ?i128 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[s.len - 1] != 'Z') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const sec = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    var nanos: i128 = 0;
    if (s[19] == '.') {
        const frac = s[20 .. s.len - 1];
        if (frac.len == 0 or frac.len > 9) return null;
        nanos = std.fmt.parseInt(i128, frac, 10) catch return null;
        for (frac.len..9) |_| nanos *= 10;
    }
    if (y == 1) return 0; // Docker's zero time
    // Days from civil (Howard Hinnant's algorithm).
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const doy = @divFloor(153 * (if (mo > 2) mo - 3 else mo + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    const secs = days * 86400 + h * 3600 + mi * 60 + sec;
    return @as(i128, secs) * std.time.ns_per_s + nanos;
}

test "rfc3339 round trip" {
    var buf: [40]u8 = undefined;
    const t: i128 = 1790793540 * std.time.ns_per_s + 123;
    try std.testing.expectEqual(t, parseRfc3339(rfc3339(&buf, t)).?);
    try std.testing.expectEqual(@as(i128, 0), parseRfc3339("0001-01-01T00:00:00Z").?);
    try std.testing.expectEqual(null, parseRfc3339("garbage"));
}

test "rfc3339 formatting" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("2026-09-30T18:39:00.000000005Z", rfc3339(&buf, 1790793540 * std.time.ns_per_s + 5));
    try std.testing.expectEqualStrings("0001-01-01T00:00:00Z", rfc3339(&buf, 0));
}

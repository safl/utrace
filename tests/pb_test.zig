// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause

//! The wire runtime's bytes, checked against encodings worked out by hand from the protobuf
//! encoding specification.

const std = @import("std");
const c = @import("c");

/// Bytes from hex pairs; spaces are ignored
fn hex(comptime s: []const u8) [std.mem.replacementSize(u8, s, " ", "") / 2]u8 {
    @setEvalBranchQuota(10000);
    var digits: [std.mem.replacementSize(u8, s, " ", "")]u8 = undefined;
    _ = std.mem.replace(u8, s, " ", "", &digits);
    var out: [digits.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, &digits) catch unreachable;
    return out;
}

const Fixture = struct {
    buf: [128]u8 = undefined,
    out: [128]u8 = undefined,
    mem: c.struct_utrace_pb_mem = undefined,
    w: c.struct_utrace_pb_writer = undefined,

    fn init(f: *Fixture, cap: usize) void {
        f.mem = .{ .data = &f.out, .cap = f.out.len, .len = 0 };
        c.utrace_pb_init(&f.w, &f.buf, cap, c.utrace_pb_mem_sink(&f.mem));
    }

    fn expectWritten(f: *Fixture, comptime expected: []const u8) !void {
        try std.testing.expectEqual(@as(c_int, 0), c.utrace_pb_flush(&f.w));
        try std.testing.expectEqualSlices(u8, &hex(expected), f.out[0..f.mem.len]);
    }
};

test "varints" {
    var f: Fixture = .{};
    f.init(64);
    c.utrace_pb_field_varint(&f.w, 1, 0);
    c.utrace_pb_field_varint(&f.w, 1, 300);
    c.utrace_pb_field_varint(&f.w, 2, std.math.maxInt(u64));
    // int32 -1 widens to ten bytes
    c.utrace_pb_field_varint(&f.w, 3, @bitCast(@as(i64, -1)));
    try f.expectWritten("08 00" ++
        "08 ac 02" ++
        "10 ff ff ff ff ff ff ff ff ff 01" ++
        "18 ff ff ff ff ff ff ff ff ff 01");
}

test "keys of large field numbers" {
    var f: Fixture = .{};
    f.init(64);
    c.utrace_pb_field_varint(&f.w, 16, 1);
    c.utrace_pb_field_varint(&f.w, (1 << 29) - 1, 1);
    try f.expectWritten("80 01 01" ++
        "f8 ff ff ff 0f 01");
}

test "zigzag" {
    try std.testing.expectEqual(@as(u64, 0), c.utrace_pb_zigzag(0));
    try std.testing.expectEqual(@as(u64, 1), c.utrace_pb_zigzag(-1));
    try std.testing.expectEqual(@as(u64, 2), c.utrace_pb_zigzag(1));
    try std.testing.expectEqual(@as(u64, 3), c.utrace_pb_zigzag(-2));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64) - 1), c.utrace_pb_zigzag(std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), c.utrace_pb_zigzag(std.math.minInt(i64)));
}

test "fixed width is little-endian" {
    var f: Fixture = .{};
    f.init(64);
    c.utrace_pb_field_fixed64(&f.w, 1, 0x0102030405060708);
    c.utrace_pb_field_fixed32(&f.w, 2, 0x01020304);
    c.utrace_pb_field_double(&f.w, 3, 1.0);
    c.utrace_pb_field_float(&f.w, 4, -2.0);
    try f.expectWritten("09 08 07 06 05 04 03 02 01" ++
        "15 04 03 02 01" ++
        "19 00 00 00 00 00 00 f0 3f" ++
        "25 00 00 00 c0");
}

test "strings and bytes" {
    var f: Fixture = .{};
    f.init(64);
    c.utrace_pb_field_string(&f.w, 1, "abc");
    c.utrace_pb_field_string(&f.w, 2, null);
    c.utrace_pb_field_bytes(&f.w, 3, "\x00\x01", 2);
    try f.expectWritten("0a 03 61 62 63" ++
        "12 00" ++
        "1a 02 00 01");
}

test "nested lengths are padded varints" {
    var f: Fixture = .{};
    f.init(64);
    c.utrace_pb_begin(&f.w, 1);
    c.utrace_pb_field_varint(&f.w, 1, 1);
    c.utrace_pb_begin(&f.w, 2);
    c.utrace_pb_end(&f.w);
    c.utrace_pb_end(&f.w);
    try f.expectWritten("0a 87 80 80 00" ++
        "08 01" ++
        "12 80 80 80 00");
}

test "a nested length uses every byte of its prefix" {
    // 200 bytes is 0x48 0x01 as a plain varint; padded it is 0xc8 0x81 0x80 0x00
    var buf: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var mem: c.struct_utrace_pb_mem = .{ .data = &out, .cap = out.len, .len = 0 };
    var w: c.struct_utrace_pb_writer = undefined;
    c.utrace_pb_init(&w, &buf, buf.len, c.utrace_pb_mem_sink(&mem));
    c.utrace_pb_begin(&w, 1);
    const payload = [_]u8{0x55} ** 197;
    c.utrace_pb_field_bytes(&w, 1, &payload, payload.len);
    c.utrace_pb_end(&w);
    try std.testing.expectEqual(@as(c_int, 0), c.utrace_pb_flush(&w));
    try std.testing.expectEqualSlices(u8, &hex("0a c8 81 80 00 0a c5 01"), out[0..8]);
    try std.testing.expectEqual(@as(usize, 205), mem.len);
}

test "a top-level message flushes once the buffer is half full" {
    var f: Fixture = .{};
    f.init(16);
    c.utrace_pb_begin(&f.w, 1);
    c.utrace_pb_field_varint(&f.w, 1, 1);
    c.utrace_pb_end(&f.w);
    try std.testing.expectEqual(@as(usize, 0), f.mem.len);
    c.utrace_pb_begin(&f.w, 1);
    c.utrace_pb_end(&f.w);
    try std.testing.expectEqual(@as(usize, 12), f.mem.len);
    try std.testing.expectEqual(@as(usize, 0), f.w.len);
}

test "running out of buffer is sticky" {
    var f: Fixture = .{};
    f.init(8);
    c.utrace_pb_field_string(&f.w, 1, "too long for eight bytes");
    try std.testing.expectEqual(@as(c_int, c.UTRACE_PB_ENOSPC), c.utrace_pb_error(&f.w));
    c.utrace_pb_field_varint(&f.w, 1, 1);
    try std.testing.expectEqual(@as(c_int, c.UTRACE_PB_ENOSPC), c.utrace_pb_flush(&f.w));
    try std.testing.expectEqual(@as(usize, 0), f.mem.len);
}

test "a full memory sink fails the writer" {
    var f: Fixture = .{};
    f.init(64);
    f.mem.cap = 2;
    c.utrace_pb_field_varint(&f.w, 1, 300);
    try std.testing.expectEqual(@as(c_int, c.UTRACE_PB_ENOSPC), c.utrace_pb_flush(&f.w));
}

test "nesting is bounded" {
    var f: Fixture = .{};
    f.init(128);
    for (0..c.UTRACE_PB_MAX_DEPTH) |_| c.utrace_pb_begin(&f.w, 1);
    try std.testing.expectEqual(@as(c_int, 0), c.utrace_pb_error(&f.w));
    c.utrace_pb_begin(&f.w, 1);
    try std.testing.expectEqual(@as(c_int, c.UTRACE_PB_EINVAL), c.utrace_pb_error(&f.w));
}

test "an end without a begin fails" {
    var f: Fixture = .{};
    f.init(64);
    c.utrace_pb_end(&f.w);
    try std.testing.expectEqual(@as(c_int, c.UTRACE_PB_EINVAL), c.utrace_pb_error(&f.w));
}

test "flushing inside a message fails" {
    var f: Fixture = .{};
    f.init(64);
    c.utrace_pb_begin(&f.w, 1);
    try std.testing.expectEqual(@as(c_int, c.UTRACE_PB_EINVAL), c.utrace_pb_flush(&f.w));
}

fn failing(_: ?*anyopaque, _: [*c]const u8, _: usize) callconv(.c) c_int {
    return -7;
}

test "a sink's error is kept" {
    var buf: [16]u8 = undefined;
    var w: c.struct_utrace_pb_writer = undefined;
    c.utrace_pb_init(&w, &buf, buf.len, .{ .write = failing, .ctx = null });
    c.utrace_pb_field_varint(&w, 1, 1);
    try std.testing.expectEqual(@as(c_int, -7), c.utrace_pb_flush(&w));
}

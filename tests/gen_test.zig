// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause

//! Writes every kind of field through the writers tools/gen emits for tests/gen/all_types.proto,
//! and reads them back by name against protoc's descriptor of it.

const std = @import("std");
const c = @import("c");
const pb = @import("pb");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn enumValue(set: pb.DescriptorSet, enum_name: []const u8, value_name: []const u8) !i64 {
    const e = set.enumType(enum_name) orelse return error.NoSuchEnum;
    for (e.values) |v| if (std.mem.eql(u8, v.name, value_name)) return v.number;
    return error.NoSuchValue;
}

fn ints(arena: std.mem.Allocator, m: pb.Message, name: []const u8) ![]const u64 {
    const values = try m.all(arena, name);
    const out = try arena.alloc(u64, values.len);
    for (values, out) |v, *o| o.* = v.int;
    return out;
}

test "every kind of field reads back as written" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const set = try pb.DescriptorSet.parse(arena, @embedFile("all_types.pb"));

    var buf: [1024]u8 = undefined;
    var out: [1024]u8 = undefined;
    var mem: c.struct_utrace_pb_mem = .{ .data = &out, .cap = out.len, .len = 0 };
    var w: c.struct_utrace_pb_writer = undefined;
    c.utrace_pb_init(&w, &buf, buf.len, c.utrace_pb_mem_sink(&mem));

    c.utrace_perfetto_AllTypes_set_f_double(&w, -1.25);
    c.utrace_perfetto_AllTypes_set_f_float(&w, 3.5);
    c.utrace_perfetto_AllTypes_set_f_int64(&w, std.math.minInt(i64));
    c.utrace_perfetto_AllTypes_set_f_uint64(&w, std.math.maxInt(u64));
    c.utrace_perfetto_AllTypes_set_f_int32(&w, -2);
    c.utrace_perfetto_AllTypes_set_f_fixed64(&w, 0x0102030405060708);
    c.utrace_perfetto_AllTypes_set_f_fixed32(&w, 0x01020304);
    c.utrace_perfetto_AllTypes_set_f_bool(&w, 7);
    c.utrace_perfetto_AllTypes_set_f_string(&w, "string");
    c.utrace_perfetto_AllTypes_set_f_bytes(&w, "\x00\xff", 2);
    c.utrace_perfetto_AllTypes_set_f_uint32(&w, std.math.maxInt(u32));
    c.utrace_perfetto_AllTypes_set_f_enum(&w, c.utrace_perfetto_AllTypes_INNER_B);
    c.utrace_perfetto_AllTypes_set_f_sfixed32(&w, -3);
    c.utrace_perfetto_AllTypes_set_f_sfixed64(&w, -4);
    c.utrace_perfetto_AllTypes_set_f_sint32(&w, std.math.minInt(i32));
    c.utrace_perfetto_AllTypes_set_f_sint64(&w, std.math.minInt(i64));
    c.utrace_perfetto_AllTypes_set_f_top(&w, c.utrace_perfetto_TOP_NEGATIVE);
    c.utrace_perfetto_AllTypes_begin_f_nested(&w);
    c.utrace_perfetto_AllTypes_Nested_set_x(&w, 1);
    c.utrace_perfetto_AllTypes_Nested_begin_deeper(&w);
    c.utrace_perfetto_AllTypes_Nested_set_x(&w, 2);
    c.utrace_pb_end(&w);
    c.utrace_pb_end(&w);

    c.utrace_perfetto_AllTypes_add_r_int64(&w, 10);
    c.utrace_perfetto_AllTypes_add_r_int64(&w, -10);
    c.utrace_perfetto_AllTypes_add_r_string(&w, "a");
    c.utrace_perfetto_AllTypes_add_r_string_n(&w, "bcd", 2);
    c.utrace_perfetto_AllTypes_begin_r_nested(&w);
    c.utrace_pb_end(&w);
    c.utrace_perfetto_AllTypes_begin_r_nested(&w);
    c.utrace_perfetto_AllTypes_Nested_set_x(&w, 3);
    c.utrace_pb_end(&w);

    const p_double = [_]f64{ 0.5, -0.5 };
    const p_float = [_]f32{ 0.25, -0.25 };
    const p_int64 = [_]i64{ -1, 1 };
    const p_uint64 = [_]u64{ 300, std.math.maxInt(u64) };
    const p_int32 = [_]i32{ -1, 1 };
    const p_fixed64 = [_]u64{ 1, 2 };
    const p_fixed32 = [_]u32{ 3, 4 };
    const p_bool = [_]c_int{ 0, 5 };
    const p_uint32 = [_]u32{ 5, 6 };
    const p_enum = [_]i32{ c.utrace_perfetto_AllTypes_INNER_A, c.utrace_perfetto_AllTypes_INNER_B };
    const p_sfixed32 = [_]i32{ -7, 7 };
    const p_sfixed64 = [_]i64{ -8, 8 };
    const p_sint32 = [_]i32{ -9, 9 };
    const p_sint64 = [_]i64{ -10, 10 };
    c.utrace_perfetto_AllTypes_set_p_double(&w, &p_double, p_double.len);
    c.utrace_perfetto_AllTypes_set_p_float(&w, &p_float, p_float.len);
    c.utrace_perfetto_AllTypes_set_p_int64(&w, &p_int64, p_int64.len);
    c.utrace_perfetto_AllTypes_set_p_uint64(&w, &p_uint64, p_uint64.len);
    c.utrace_perfetto_AllTypes_set_p_int32(&w, &p_int32, p_int32.len);
    c.utrace_perfetto_AllTypes_set_p_fixed64(&w, &p_fixed64, p_fixed64.len);
    c.utrace_perfetto_AllTypes_set_p_fixed32(&w, &p_fixed32, p_fixed32.len);
    c.utrace_perfetto_AllTypes_set_p_bool(&w, &p_bool, p_bool.len);
    c.utrace_perfetto_AllTypes_set_p_uint32(&w, &p_uint32, p_uint32.len);
    c.utrace_perfetto_AllTypes_set_p_enum(&w, &p_enum, p_enum.len);
    c.utrace_perfetto_AllTypes_set_p_sfixed32(&w, &p_sfixed32, p_sfixed32.len);
    c.utrace_perfetto_AllTypes_set_p_sfixed64(&w, &p_sfixed64, p_sfixed64.len);
    c.utrace_perfetto_AllTypes_set_p_sint32(&w, &p_sint32, p_sint32.len);
    c.utrace_perfetto_AllTypes_set_p_sint64(&w, &p_sint64, p_sint64.len);

    c.utrace_perfetto_AllTypes_set_f_highest(&w, 1);
    try expectEqual(@as(c_int, 0), c.utrace_pb_flush(&w));

    const desc = set.message("utrace.test.AllTypes").?;
    const m = try pb.Message.decode(arena, set, desc, out[0..mem.len]);

    try expectEqual(@as(f64, -1.25), (try m.one("f_double")).double);
    try expectEqual(@as(f32, 3.5), (try m.one("f_float")).float);
    try expectEqual(@as(i64, std.math.minInt(i64)), try m.signed("f_int64"));
    try expectEqual(@as(u64, std.math.maxInt(u64)), try m.int("f_uint64"));
    try expectEqual(@as(i64, -2), try m.signed("f_int32"));
    try expectEqual(@as(u64, 0x0102030405060708), try m.int("f_fixed64"));
    try expectEqual(@as(u64, 0x01020304), try m.int("f_fixed32"));
    try expectEqual(@as(u64, 1), try m.int("f_bool"));
    try expectEqualStrings("string", try m.str("f_string"));
    try expectEqualStrings("\x00\xff", try m.str("f_bytes"));
    try expectEqual(@as(u64, std.math.maxInt(u32)), try m.int("f_uint32"));
    try expectEqual(try enumValue(set, "utrace.test.AllTypes.Inner", "INNER_B"), try m.signed("f_enum"));
    try expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -3)))), try m.int("f_sfixed32"));
    try expectEqual(@as(i64, -4), try m.signed("f_sfixed64"));
    try expectEqual(@as(i64, std.math.minInt(i32)), try m.signed("f_sint32"));
    try expectEqual(@as(i64, std.math.minInt(i64)), try m.signed("f_sint64"));
    try expectEqual(try enumValue(set, "utrace.test.Top", "TOP_NEGATIVE"), try m.signed("f_top"));
    const nested = try m.msg("f_nested");
    try expectEqual(@as(u64, 1), try nested.int("x"));
    try expectEqual(@as(u64, 2), try (try nested.msg("deeper")).int("x"));

    try std.testing.expectEqualSlices(u64, &.{ 10, @bitCast(@as(i64, -10)) }, try ints(arena, m, "r_int64"));
    const strings = try m.all(arena, "r_string");
    try expectEqual(@as(usize, 2), strings.len);
    try expectEqualStrings("a", strings[0].bytes);
    try expectEqualStrings("bc", strings[1].bytes);
    const r_nested = try m.all(arena, "r_nested");
    try expectEqual(@as(usize, 2), r_nested.len);
    try expect(!try r_nested[0].message.has("x"));
    try expectEqual(@as(u64, 3), try r_nested[1].message.int("x"));

    const doubles = try m.all(arena, "p_double");
    try expectEqual(@as(f64, 0.5), doubles[0].double);
    try expectEqual(@as(f64, -0.5), doubles[1].double);
    const floats = try m.all(arena, "p_float");
    try expectEqual(@as(f32, 0.25), floats[0].float);
    try expectEqual(@as(f32, -0.25), floats[1].float);
    try std.testing.expectEqualSlices(u64, &.{ std.math.maxInt(u64), 1 }, try ints(arena, m, "p_int64"));
    try std.testing.expectEqualSlices(u64, &.{ 300, std.math.maxInt(u64) }, try ints(arena, m, "p_uint64"));
    try std.testing.expectEqualSlices(u64, &.{ std.math.maxInt(u64), 1 }, try ints(arena, m, "p_int32"));
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, try ints(arena, m, "p_fixed64"));
    try std.testing.expectEqualSlices(u64, &.{ 3, 4 }, try ints(arena, m, "p_fixed32"));
    try std.testing.expectEqualSlices(u64, &.{ 0, 1 }, try ints(arena, m, "p_bool"));
    try std.testing.expectEqualSlices(u64, &.{ 5, 6 }, try ints(arena, m, "p_uint32"));
    try std.testing.expectEqualSlices(u64, &.{
        @intCast(try enumValue(set, "utrace.test.AllTypes.Inner", "INNER_A")),
        @intCast(try enumValue(set, "utrace.test.AllTypes.Inner", "INNER_B")),
    }, try ints(arena, m, "p_enum"));
    try std.testing.expectEqualSlices(u64, &.{ @as(u32, @bitCast(@as(i32, -7))), 7 }, try ints(arena, m, "p_sfixed32"));
    try std.testing.expectEqualSlices(u64, &.{ @bitCast(@as(i64, -8)), 8 }, try ints(arena, m, "p_sfixed64"));
    try std.testing.expectEqualSlices(u64, &.{ @bitCast(@as(i64, -9)), 9 }, try ints(arena, m, "p_sint32"));
    try std.testing.expectEqualSlices(u64, &.{ @bitCast(@as(i64, -10)), 10 }, try ints(arena, m, "p_sint64"));

    try expectEqual(@as(u64, 1), try m.int("f_highest"));

    // every declared field was written, so a writer that targets the wrong number shows up
    for (desc.fields) |*f| try expect(try m.has(f.name));
}

test "enum constants carry the values the descriptor declares" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const set = try pb.DescriptorSet.parse(arena_state.allocator(), @embedFile("all_types.pb"));

    try expectEqual(try enumValue(set, "utrace.test.Top", "TOP_NEGATIVE"), c.utrace_perfetto_TOP_NEGATIVE);
    try expectEqual(try enumValue(set, "utrace.test.Top", "TOP_ZERO"), c.utrace_perfetto_TOP_ZERO);
    try expectEqual(try enumValue(set, "utrace.test.Top", "TOP_MAX"), c.utrace_perfetto_TOP_MAX);
    try expectEqual(try enumValue(set, "utrace.test.AllTypes.Inner", "INNER_A"), c.utrace_perfetto_AllTypes_INNER_A);
    try expectEqual(try enumValue(set, "utrace.test.AllTypes.Inner", "INNER_B"), c.utrace_perfetto_AllTypes_INNER_B);
}

test "field constants carry the numbers the descriptor declares" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const set = try pb.DescriptorSet.parse(arena_state.allocator(), @embedFile("all_types.pb"));
    const desc = set.message("utrace.test.AllTypes").?;

    var checked: usize = 0;
    @setEvalBranchQuota(1_000_000);
    inline for (@typeInfo(c).@"struct".decls) |d| {
        const prefix = "utrace_perfetto_AllTypes_FIELD_";
        if (comptime std.mem.startsWith(u8, d.name, prefix)) {
            const f = desc.field(d.name[prefix.len..]) orelse return error.NoSuchField;
            try expectEqual(@as(i64, f.number), @field(c, d.name));
            checked += 1;
        }
    }
    try expectEqual(desc.fields.len, checked);
}

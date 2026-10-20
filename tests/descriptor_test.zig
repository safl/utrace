// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause

//! tools/pb.zig decodes descriptors with field numbers of its own; here it decodes protoc's
//! descriptor of descriptor.proto itself and finds each of them there.

const std = @import("std");
const pb = @import("pb");

test "the decoder's descriptor field numbers are descriptor.proto's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const set = try pb.DescriptorSet.parse(arena, @embedFile("descriptor.pb"));

    var checked: usize = 0;
    inline for (@typeInfo(pb.numbers).@"struct".decls) |m| {
        const desc = set.message("google.protobuf." ++ m.name) orelse return error.NoSuchMessage;
        const fields = @field(pb.numbers, m.name);
        inline for (@typeInfo(fields).@"struct".decls) |f| {
            const field = desc.field(f.name) orelse return error.NoSuchField;
            try std.testing.expectEqual(@as(u32, @field(fields, f.name)), field.number);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 0);
}

test "the decoder's types and labels are descriptor.proto's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const set = try pb.DescriptorSet.parse(arena_state.allocator(), @embedFile("descriptor.pb"));

    const types = set.enumType("google.protobuf.FieldDescriptorProto.Type").?;
    for (types.values) |v| {
        var name: [32]u8 = undefined;
        const t: pb.Type = @enumFromInt(v.number);
        try std.testing.expectEqualStrings(std.ascii.lowerString(&name, v.name["TYPE_".len..]), @tagName(t));
    }
    const labels = set.enumType("google.protobuf.FieldDescriptorProto.Label").?;
    for (labels.values) |v| {
        var name: [32]u8 = undefined;
        const l: pb.Label = @enumFromInt(v.number);
        try std.testing.expectEqualStrings(std.ascii.lowerString(&name, v.name["LABEL_".len..]), @tagName(l));
    }
}

test "the wire reader rejects what is not protobuf" {
    var r: pb.Reader = .{ .buf = "\x08" };
    try std.testing.expectError(error.Truncated, r.next());
    r = .{ .buf = "\x0b" };
    try std.testing.expectError(error.BadWireType, r.next());
    r = .{ .buf = "\x00\x00" };
    try std.testing.expectError(error.BadFieldNumber, r.next());
    r = .{ .buf = "\x0a\x05abc" };
    try std.testing.expectError(error.Truncated, r.next());
    r = .{ .buf = "\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02" };
    try std.testing.expectError(error.Overlong, r.next());
}

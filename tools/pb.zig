// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause

//! A small protobuf decoder, independent of the C encoder: the wire format, the
//! FileDescriptorSet protoc writes, and messages decoded by name against it. tools/gen reads
//! protoc's output with it, and the tests read uTrace's traces with it.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Wire = enum(u3) { varint = 0, i64 = 1, len = 2, sgroup = 3, egroup = 4, i32 = 5, _ };

pub const Error = error{ Truncated, Overlong, BadWireType, BadFieldNumber };

/// One field as it is on the wire
pub const Field = struct {
    number: u32,
    wire: Wire,
    /// The value of a varint, i64 or i32 field
    int: u64 = 0,
    /// The payload of a length-delimited field
    bytes: []const u8 = "",
};

pub fn varint(buf: []const u8, pos: *usize) Error!u64 {
    var v: u64 = 0;
    var i: u7 = 0;
    while (i < 10) : (i += 1) {
        if (pos.* >= buf.len) return error.Truncated;
        const b = buf[pos.*];
        pos.* += 1;
        const bits: u64 = b & 0x7f;
        if (i == 9 and bits > 1) return error.Overlong;
        v |= bits << @intCast(7 * i);
        if (b & 0x80 == 0) return v;
    }
    return error.Overlong;
}

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(r: *Reader) Error!?Field {
        if (r.pos == r.buf.len) return null;
        const key = try varint(r.buf, &r.pos);
        const number = std.math.cast(u32, key >> 3) orelse return error.BadFieldNumber;
        if (number == 0 or number >= 1 << 29) return error.BadFieldNumber;
        var field: Field = .{ .number = number, .wire = @enumFromInt(@as(u3, @truncate(key))) };
        switch (field.wire) {
            .varint => field.int = try varint(r.buf, &r.pos),
            .i64 => field.int = std.mem.readInt(u64, (try r.take(8))[0..8], .little),
            .i32 => field.int = std.mem.readInt(u32, (try r.take(4))[0..4], .little),
            .len => {
                const n = try varint(r.buf, &r.pos);
                field.bytes = try r.take(std.math.cast(usize, n) orelse return error.Truncated);
            },
            else => return error.BadWireType,
        }
        return field;
    }

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (r.buf.len - r.pos < n) return error.Truncated;
        defer r.pos += n;
        return r.buf[r.pos..][0..n];
    }
};

pub fn unzigzag(v: u64) i64 {
    return @bitCast((v >> 1) ^ (0 -% (v & 1)));
}

/// Field numbers of google/protobuf/descriptor.proto, which tests/descriptor_test.zig checks
/// against the vendored copy of it
pub const numbers = struct {
    pub const FileDescriptorSet = struct {
        pub const file = 1;
    };
    pub const FileDescriptorProto = struct {
        pub const name = 1;
        pub const package = 2;
        pub const message_type = 4;
        pub const enum_type = 5;
    };
    pub const DescriptorProto = struct {
        pub const name = 1;
        pub const field = 2;
        pub const nested_type = 3;
        pub const enum_type = 4;
    };
    pub const FieldDescriptorProto = struct {
        pub const name = 1;
        pub const number = 3;
        pub const label = 4;
        pub const @"type" = 5;
        pub const type_name = 6;
        pub const options = 8;
    };
    pub const FieldOptions = struct {
        pub const @"packed" = 2;
    };
    pub const EnumDescriptorProto = struct {
        pub const name = 1;
        pub const value = 2;
    };
    pub const EnumValueDescriptorProto = struct {
        pub const name = 1;
        pub const number = 2;
    };
};

/// FieldDescriptorProto.Type
pub const Type = enum(u8) {
    double = 1,
    float = 2,
    int64 = 3,
    uint64 = 4,
    int32 = 5,
    fixed64 = 6,
    fixed32 = 7,
    bool = 8,
    string = 9,
    group = 10,
    message = 11,
    bytes = 12,
    uint32 = 13,
    @"enum" = 14,
    sfixed32 = 15,
    sfixed64 = 16,
    sint32 = 17,
    sint64 = 18,
    _,

    pub fn wire(t: Type) Wire {
        return switch (t) {
            .double, .fixed64, .sfixed64 => .i64,
            .float, .fixed32, .sfixed32 => .i32,
            .string, .bytes, .message => .len,
            .group => .sgroup,
            else => .varint,
        };
    }

    /// Whether repeated values of this type may be packed
    pub fn scalar(t: Type) bool {
        return t.wire() == .varint or t.wire() == .i64 or t.wire() == .i32;
    }
};

/// FieldDescriptorProto.Label
pub const Label = enum(u8) { optional = 1, required = 2, repeated = 3, _ };

pub const FieldDesc = struct {
    name: []const u8,
    number: u32 = 0,
    label: Label = .optional,
    type: Type = @enumFromInt(0),
    /// The full name of a message or enum type, without the leading dot
    type_name: []const u8 = "",
    @"packed": bool = false,
};

pub const EnumValue = struct { name: []const u8, number: i32 };

pub const EnumDesc = struct {
    name: []const u8,
    full_name: []const u8,
    values: []const EnumValue,
};

pub const MessageDesc = struct {
    name: []const u8,
    full_name: []const u8,
    fields: []const FieldDesc,
    nested: []const MessageDesc,
    enums: []const EnumDesc,

    pub fn field(m: *const MessageDesc, name: []const u8) ?*const FieldDesc {
        for (m.fields) |*f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    pub fn fieldByNumber(m: *const MessageDesc, number: u32) ?*const FieldDesc {
        for (m.fields) |*f| if (f.number == number) return f;
        return null;
    }
};

pub const FileDesc = struct {
    name: []const u8,
    package: []const u8,
    messages: []const MessageDesc,
    enums: []const EnumDesc,
};

pub const DescriptorSet = struct {
    files: []const FileDesc,

    pub const ParseError = Error || Allocator.Error || error{BadDescriptor};

    /// Everything allocated lands in arena, which outlives the set
    pub fn parse(arena: Allocator, bytes: []const u8) ParseError!DescriptorSet {
        var files: std.ArrayList(FileDesc) = .empty;
        var r: Reader = .{ .buf = bytes };
        while (try r.next()) |f| {
            if (f.number == numbers.FileDescriptorSet.file) try files.append(arena, try parseFile(arena, try expectLen(f)));
        }
        return .{ .files = try files.toOwnedSlice(arena) };
    }

    /// The message of the given full name, e.g. "perfetto.protos.TrackEvent"
    pub fn message(set: DescriptorSet, full_name: []const u8) ?*const MessageDesc {
        for (set.files) |*file| {
            for (file.messages) |*m| if (findMessage(m, full_name)) |found| return found;
        }
        return null;
    }

    pub fn enumType(set: DescriptorSet, full_name: []const u8) ?*const EnumDesc {
        for (set.files) |*file| {
            for (file.enums) |*e| if (std.mem.eql(u8, e.full_name, full_name)) return e;
            for (file.messages) |*m| if (findEnum(m, full_name)) |found| return found;
        }
        return null;
    }

    /// The file declaring the top-level message or enum of the given full name
    pub fn fileOf(set: DescriptorSet, full_name: []const u8) ?*const FileDesc {
        for (set.files) |*file| {
            for (file.messages) |*m| if (std.mem.eql(u8, m.full_name, full_name)) return file;
            for (file.enums) |*e| if (std.mem.eql(u8, e.full_name, full_name)) return file;
        }
        return null;
    }
};

fn findMessage(m: *const MessageDesc, full_name: []const u8) ?*const MessageDesc {
    if (std.mem.eql(u8, m.full_name, full_name)) return m;
    for (m.nested) |*n| if (findMessage(n, full_name)) |found| return found;
    return null;
}

fn findEnum(m: *const MessageDesc, full_name: []const u8) ?*const EnumDesc {
    for (m.enums) |*e| if (std.mem.eql(u8, e.full_name, full_name)) return e;
    for (m.nested) |*n| if (findEnum(n, full_name)) |found| return found;
    return null;
}

fn expectLen(f: Field) error{BadDescriptor}![]const u8 {
    if (f.wire != .len) return error.BadDescriptor;
    return f.bytes;
}

fn expectInt(f: Field) error{BadDescriptor}!u64 {
    if (f.wire != .varint) return error.BadDescriptor;
    return f.int;
}

fn join(arena: Allocator, scope: []const u8, name: []const u8) Allocator.Error![]const u8 {
    if (scope.len == 0) return name;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ scope, name });
}

fn parseFile(arena: Allocator, bytes: []const u8) DescriptorSet.ParseError!FileDesc {
    const n = numbers.FileDescriptorProto;
    var file: FileDesc = .{ .name = "", .package = "", .messages = &.{}, .enums = &.{} };
    // the package comes before the types in protoc's output, but the wire does not promise that
    var r: Reader = .{ .buf = bytes };
    while (try r.next()) |f| switch (f.number) {
        n.name => file.name = try expectLen(f),
        n.package => file.package = try expectLen(f),
        else => {},
    };
    var messages: std.ArrayList(MessageDesc) = .empty;
    var enums: std.ArrayList(EnumDesc) = .empty;
    r = .{ .buf = bytes };
    while (try r.next()) |f| switch (f.number) {
        n.message_type => try messages.append(arena, try parseMessage(arena, file.package, try expectLen(f))),
        n.enum_type => try enums.append(arena, try parseEnum(arena, file.package, try expectLen(f))),
        else => {},
    };
    file.messages = try messages.toOwnedSlice(arena);
    file.enums = try enums.toOwnedSlice(arena);
    return file;
}

fn parseMessage(arena: Allocator, scope: []const u8, bytes: []const u8) DescriptorSet.ParseError!MessageDesc {
    const n = numbers.DescriptorProto;
    var name: []const u8 = "";
    var r: Reader = .{ .buf = bytes };
    while (try r.next()) |f| {
        if (f.number == n.name) name = try expectLen(f);
    }
    const full_name = try join(arena, scope, name);
    var fields: std.ArrayList(FieldDesc) = .empty;
    var nested: std.ArrayList(MessageDesc) = .empty;
    var enums: std.ArrayList(EnumDesc) = .empty;
    r = .{ .buf = bytes };
    while (try r.next()) |f| switch (f.number) {
        n.field => try fields.append(arena, try parseField(try expectLen(f))),
        n.nested_type => try nested.append(arena, try parseMessage(arena, full_name, try expectLen(f))),
        n.enum_type => try enums.append(arena, try parseEnum(arena, full_name, try expectLen(f))),
        else => {},
    };
    return .{
        .name = name,
        .full_name = full_name,
        .fields = try fields.toOwnedSlice(arena),
        .nested = try nested.toOwnedSlice(arena),
        .enums = try enums.toOwnedSlice(arena),
    };
}

fn parseField(bytes: []const u8) DescriptorSet.ParseError!FieldDesc {
    const n = numbers.FieldDescriptorProto;
    var field: FieldDesc = .{ .name = "" };
    var r: Reader = .{ .buf = bytes };
    while (try r.next()) |f| switch (f.number) {
        n.name => field.name = try expectLen(f),
        n.number => field.number = std.math.cast(u32, try expectInt(f)) orelse return error.BadDescriptor,
        n.label => field.label = @enumFromInt(std.math.cast(u8, try expectInt(f)) orelse return error.BadDescriptor),
        n.type => field.type = @enumFromInt(std.math.cast(u8, try expectInt(f)) orelse return error.BadDescriptor),
        n.type_name => {
            const name = try expectLen(f);
            field.type_name = if (std.mem.startsWith(u8, name, ".")) name[1..] else name;
        },
        n.options => {
            var o: Reader = .{ .buf = try expectLen(f) };
            while (try o.next()) |opt| {
                if (opt.number == numbers.FieldOptions.@"packed") field.@"packed" = try expectInt(opt) != 0;
            }
        },
        else => {},
    };
    return field;
}

fn parseEnum(arena: Allocator, scope: []const u8, bytes: []const u8) DescriptorSet.ParseError!EnumDesc {
    const n = numbers.EnumDescriptorProto;
    var name: []const u8 = "";
    var values: std.ArrayList(EnumValue) = .empty;
    var r: Reader = .{ .buf = bytes };
    while (try r.next()) |f| switch (f.number) {
        n.name => name = try expectLen(f),
        n.value => {
            var value: EnumValue = .{ .name = "", .number = 0 };
            var v: Reader = .{ .buf = try expectLen(f) };
            while (try v.next()) |vf| switch (vf.number) {
                numbers.EnumValueDescriptorProto.name => value.name = try expectLen(vf),
                // int32 on the wire is a sign-extended 64-bit varint
                numbers.EnumValueDescriptorProto.number => value.number = std.math.cast(i32, @as(i64, @bitCast(try expectInt(vf)))) orelse return error.BadDescriptor,
                else => {},
            };
            try values.append(arena, value);
        },
        else => {},
    };
    return .{ .name = name, .full_name = try join(arena, scope, name), .values = try values.toOwnedSlice(arena) };
}

/// A field's value as decoded against its declaration
pub const Value = union(enum) {
    /// Every varint and fixed-width type, as its bits; sint32 and sint64 are zigzag-decoded
    int: u64,
    double: f64,
    float: f32,
    bytes: []const u8,
    message: Message,
};

/// A message decoded against its descriptor: every field it carries, in wire order
pub const Message = struct {
    desc: *const MessageDesc,
    fields: []const Entry,

    pub const Entry = struct { field: *const FieldDesc, value: Value };

    pub const DecodeError = Error || Allocator.Error || error{ UnknownField, WrongWireType, UnknownType };

    /// Decodes bytes as the message desc describes, failing on any field it does not declare
    /// or carries with the wrong wire type
    pub fn decode(arena: Allocator, set: DescriptorSet, desc: *const MessageDesc, bytes: []const u8) DecodeError!Message {
        var entries: std.ArrayList(Entry) = .empty;
        var r: Reader = .{ .buf = bytes };
        while (try r.next()) |f| {
            const fd = desc.fieldByNumber(f.number) orelse return error.UnknownField;
            if (f.wire == .len and fd.type.scalar()) {
                try decodePacked(arena, &entries, fd, f.bytes);
                continue;
            }
            if (f.wire != fd.type.wire()) return error.WrongWireType;
            try entries.append(arena, .{ .field = fd, .value = switch (fd.type) {
                .double => .{ .double = @bitCast(f.int) },
                .float => .{ .float = @bitCast(@as(u32, @truncate(f.int))) },
                .sint32, .sint64 => .{ .int = @bitCast(unzigzag(f.int)) },
                .string, .bytes => .{ .bytes = f.bytes },
                .message => .{ .message = try decode(arena, set, set.message(fd.type_name) orelse return error.UnknownType, f.bytes) },
                else => .{ .int = f.int },
            } });
        }
        return .{ .desc = desc, .fields = try entries.toOwnedSlice(arena) };
    }

    fn decodePacked(arena: Allocator, entries: *std.ArrayList(Entry), fd: *const FieldDesc, bytes: []const u8) DecodeError!void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const bits: u64 = switch (fd.type.wire()) {
                .varint => try varint(bytes, &pos),
                .i64 => blk: {
                    if (bytes.len - pos < 8) return error.Truncated;
                    defer pos += 8;
                    break :blk std.mem.readInt(u64, bytes[pos..][0..8], .little);
                },
                else => blk: {
                    if (bytes.len - pos < 4) return error.Truncated;
                    defer pos += 4;
                    break :blk std.mem.readInt(u32, bytes[pos..][0..4], .little);
                },
            };
            try entries.append(arena, .{ .field = fd, .value = switch (fd.type) {
                .double => .{ .double = @bitCast(bits) },
                .float => .{ .float = @bitCast(@as(u32, @truncate(bits))) },
                .sint32, .sint64 => .{ .int = @bitCast(unzigzag(bits)) },
                else => .{ .int = bits },
            } });
        }
    }

    /// Every value of the named field, which must be declared
    pub fn all(m: Message, arena: Allocator, name: []const u8) ![]const Value {
        const fd = m.desc.field(name) orelse return error.NoSuchField;
        var values: std.ArrayList(Value) = .empty;
        for (m.fields) |e| if (e.field == fd) try values.append(arena, e.value);
        return values.toOwnedSlice(arena);
    }

    pub fn has(m: Message, name: []const u8) !bool {
        const fd = m.desc.field(name) orelse return error.NoSuchField;
        for (m.fields) |e| if (e.field == fd) return true;
        return false;
    }

    /// The named field's one value; absent or repeated is an error
    pub fn one(m: Message, name: []const u8) !Value {
        const fd = m.desc.field(name) orelse return error.NoSuchField;
        var found: ?Value = null;
        for (m.fields) |e| if (e.field == fd) {
            if (found != null) return error.Repeated;
            found = e.value;
        };
        return found orelse error.Absent;
    }

    pub fn int(m: Message, name: []const u8) !u64 {
        return switch (try m.one(name)) {
            .int => |v| v,
            else => error.NotAnInt,
        };
    }

    pub fn signed(m: Message, name: []const u8) !i64 {
        return @bitCast(try m.int(name));
    }

    pub fn str(m: Message, name: []const u8) ![]const u8 {
        return switch (try m.one(name)) {
            .bytes => |v| v,
            else => error.NotBytes,
        };
    }

    pub fn msg(m: Message, name: []const u8) !Message {
        return switch (try m.one(name)) {
            .message => |v| v,
            else => error.NotAMessage,
        };
    }
};

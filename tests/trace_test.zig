// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause

//! Writes traces through utrace.h and reads every packet back by field name against protoc's
//! descriptor of Perfetto's protos, so a field the API writes under a wrong number, or with a
//! wrong type, fails here rather than vanishing in Perfetto.

const std = @import("std");
const c = @import("c");
const pb = @import("pb");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Allocator = std.mem.Allocator;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    set: pb.DescriptorSet = undefined,
    buf: [4096]u8 = undefined,
    out: [16384]u8 = undefined,
    mem: c.struct_utrace_pb_mem = undefined,
    t: c.struct_utrace = undefined,

    fn init(f: *Fixture, opts: ?*const c.struct_utrace_opts) !void {
        f.arena_state = .init(std.testing.allocator);
        f.set = try pb.DescriptorSet.parse(f.arena(), @embedFile("perfetto.pb"));
        f.mem = .{ .data = &f.out, .cap = f.out.len, .len = 0 };
        try expectEqual(@as(c_int, 0), c.utrace_open(&f.t, &f.buf, f.buf.len, c.utrace_pb_mem_sink(&f.mem), opts));
    }

    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
    }

    fn arena(f: *Fixture) Allocator {
        return f.arena_state.allocator();
    }

    /// Closes the trace and decodes it as a perfetto.protos.Trace
    fn packets(f: *Fixture) ![]const pb.Message {
        try expectEqual(@as(c_int, 0), c.utrace_close(&f.t));
        const trace = try pb.Message.decode(f.arena(), f.set, f.set.message("perfetto.protos.Trace").?, f.out[0..f.mem.len]);
        const values = try trace.all(f.arena(), "packet");
        const out = try f.arena().alloc(pb.Message, values.len);
        for (values, out) |v, *o| o.* = v.message;
        return out;
    }

    fn enumValue(f: *Fixture, enum_name: []const u8, value_name: []const u8) !u64 {
        const e = f.set.enumType(enum_name) orelse return error.NoSuchEnum;
        for (e.values) |v| if (std.mem.eql(u8, v.name, value_name)) return @bitCast(@as(i64, v.number));
        return error.NoSuchValue;
    }

    fn eventType(f: *Fixture, name: []const u8) !u64 {
        return f.enumValue("perfetto.protos.TrackEvent.Type", name);
    }

    fn clock(f: *Fixture, name: []const u8) !u64 {
        return f.enumValue("perfetto.protos.BuiltinClock", name);
    }
};

fn ints(arena: Allocator, m: pb.Message, name: []const u8) ![]const u64 {
    const values = try m.all(arena, name);
    const out = try arena.alloc(u64, values.len);
    for (values, out) |v, *o| o.* = v.int;
    return out;
}

/// The debug annotation of the given name
fn arg(arena: Allocator, event: pb.Message, name: []const u8) !pb.Message {
    for (try event.all(arena, "debug_annotations")) |a| {
        if (std.mem.eql(u8, try a.message.str("name"), name)) return a.message;
    }
    return error.NoSuchArg;
}

fn expectSequence(p: pb.Message, id: u64) !void {
    try expectEqual(id, try p.int("trusted_packet_sequence_id"));
}

test "tracks are described as declared" {
    var f: Fixture = .{ .arena_state = undefined };
    try f.init(null);
    defer f.deinit();

    c.utrace_track_process(&f.t, 1, 4242, "proc");
    c.utrace_track_thread(&f.t, 2, 4242, 4243, "thread");
    c.utrace_track(&f.t, 3, 1, "device");
    c.utrace_track(&f.t, 4, 0, "global");
    c.utrace_track_counter(&f.t, 5, 3, "counter", "bytes");
    c.utrace_track_counter(&f.t, 6, 0, "unitless", null);
    const ps = try f.packets();
    try expectEqual(@as(usize, 6), ps.len);

    for (ps, 0..) |p, i| {
        try expectSequence(p, 1);
        try expect(!try p.has("timestamp"));
        try expectEqual(i == 0, try p.has("sequence_flags"));
        try expectEqual(i == 0, try p.has("first_packet_on_sequence"));
    }
    try expectEqual(try f.enumValue("perfetto.protos.TracePacket.SequenceFlags", "SEQ_INCREMENTAL_STATE_CLEARED"), try ps[0].int("sequence_flags"));
    try expectEqual(@as(u64, 1), try ps[0].int("first_packet_on_sequence"));

    const process = try ps[0].msg("track_descriptor");
    try expectEqual(@as(u64, 1), try process.int("uuid"));
    try expect(!try process.has("parent_uuid"));
    try expectEqual(@as(i64, 4242), try (try process.msg("process")).signed("pid"));
    try expectEqualStrings("proc", try (try process.msg("process")).str("process_name"));

    const thread = try ps[1].msg("track_descriptor");
    try expectEqual(@as(u64, 2), try thread.int("uuid"));
    try expect(!try thread.has("parent_uuid"));
    try expectEqual(@as(i64, 4242), try (try thread.msg("thread")).signed("pid"));
    try expectEqual(@as(i64, 4243), try (try thread.msg("thread")).signed("tid"));
    try expectEqualStrings("thread", try (try thread.msg("thread")).str("thread_name"));

    const device = try ps[2].msg("track_descriptor");
    try expectEqual(@as(u64, 3), try device.int("uuid"));
    try expectEqual(@as(u64, 1), try device.int("parent_uuid"));
    try expectEqualStrings("device", try device.str("name"));

    const global = try ps[3].msg("track_descriptor");
    try expectEqual(@as(u64, 4), try global.int("uuid"));
    try expect(!try global.has("parent_uuid"));
    try expectEqualStrings("global", try global.str("name"));

    const counter = try ps[4].msg("track_descriptor");
    try expectEqual(@as(u64, 5), try counter.int("uuid"));
    try expectEqual(@as(u64, 3), try counter.int("parent_uuid"));
    try expectEqualStrings("counter", try counter.str("name"));
    try expectEqualStrings("bytes", try (try counter.msg("counter")).str("unit_name"));

    const unitless = try ps[5].msg("track_descriptor");
    try expect(!try (try unitless.msg("counter")).has("unit_name"));
}

test "events carry their type, track, time, name, categories, flows and arguments" {
    var f: Fixture = .{ .arena_state = undefined };
    try f.init(null);
    defer f.deinit();
    const a = f.arena_state.allocator();

    c.utrace_event_start(&f.t, c.UTRACE_SLICE_BEGIN, 2, 1000);
    c.utrace_event_name(&f.t, "submit");
    c.utrace_event_category(&f.t, "host");
    c.utrace_event_category(&f.t, "io");
    c.utrace_event_flow(&f.t, 7);
    c.utrace_event_flow(&f.t, std.math.maxInt(u64));
    c.utrace_event_arg_int(&f.t, "int", -5);
    c.utrace_event_arg_uint(&f.t, "uint", std.math.maxInt(u64));
    c.utrace_event_arg_double(&f.t, "double", 0.5);
    c.utrace_event_arg_bool(&f.t, "bool", 1);
    c.utrace_event_arg_str(&f.t, "str", "value");
    c.utrace_event_finish(&f.t);
    c.utrace_slice_end(&f.t, 2, 1100);
    c.utrace_slice_begin(&f.t, 3, 1200, "kernel");
    c.utrace_event_start(&f.t, c.UTRACE_SLICE_END, 3, 1300);
    c.utrace_event_flow_end(&f.t, 7);
    c.utrace_event_finish(&f.t);
    c.utrace_instant(&f.t, 2, 1400, "sync");
    c.utrace_counter(&f.t, 5, 1500, -3);
    c.utrace_counter_double(&f.t, 6, 1600, 2.25);
    const ps = try f.packets();
    try expectEqual(@as(usize, 7), ps.len);

    const timestamps = [_]u64{ 1000, 1100, 1200, 1300, 1400, 1500, 1600 };
    const types = [_][]const u8{ "TYPE_SLICE_BEGIN", "TYPE_SLICE_END", "TYPE_SLICE_BEGIN", "TYPE_SLICE_END", "TYPE_INSTANT", "TYPE_COUNTER", "TYPE_COUNTER" };
    const tracks = [_]u64{ 2, 2, 3, 3, 2, 5, 6 };
    for (ps, timestamps, types, tracks) |p, ts, ty, track| {
        try expectSequence(p, 1);
        try expectEqual(ts, try p.int("timestamp"));
        try expect(!try p.has("timestamp_clock_id"));
        const e = try p.msg("track_event");
        try expectEqual(try f.eventType(ty), try e.int("type"));
        try expectEqual(track, try e.int("track_uuid"));
    }

    const submit = try ps[0].msg("track_event");
    try expectEqualStrings("submit", try submit.str("name"));
    const categories = try submit.all(a, "categories");
    try expectEqual(@as(usize, 2), categories.len);
    try expectEqualStrings("host", categories[0].bytes);
    try expectEqualStrings("io", categories[1].bytes);
    try std.testing.expectEqualSlices(u64, &.{ 7, std.math.maxInt(u64) }, try ints(a, submit, "flow_ids"));
    try expect(!try submit.has("terminating_flow_ids"));
    try expectEqual(@as(usize, 5), (try submit.all(a, "debug_annotations")).len);
    try expectEqual(@as(i64, -5), try (try arg(a, submit, "int")).signed("int_value"));
    try expectEqual(@as(u64, std.math.maxInt(u64)), try (try arg(a, submit, "uint")).int("uint_value"));
    try expectEqual(@as(f64, 0.5), (try (try arg(a, submit, "double")).one("double_value")).double);
    try expectEqual(@as(u64, 1), try (try arg(a, submit, "bool")).int("bool_value"));
    try expectEqualStrings("value", try (try arg(a, submit, "str")).str("string_value"));

    const end = try ps[1].msg("track_event");
    try expect(!try end.has("name"));
    try expectEqualStrings("kernel", try (try ps[2].msg("track_event")).str("name"));
    const kernel_end = try ps[3].msg("track_event");
    try std.testing.expectEqualSlices(u64, &.{7}, try ints(a, kernel_end, "terminating_flow_ids"));
    try expect(!try kernel_end.has("flow_ids"));
    try expectEqualStrings("sync", try (try ps[4].msg("track_event")).str("name"));
    try expectEqual(@as(i64, -3), try (try ps[5].msg("track_event")).signed("counter_value"));
    try expectEqual(@as(f64, 2.25), (try (try ps[6].msg("track_event")).one("double_counter_value")).double);
}

test "a clock other than BOOTTIME is named on every timestamp and made the trace's" {
    var f: Fixture = .{ .arena_state = undefined };
    const opts: c.struct_utrace_opts = .{ .clock_id = c.utrace_perfetto_BUILTIN_CLOCK_MONOTONIC, .sequence_id = 9 };
    try f.init(&opts);
    defer f.deinit();
    const a = f.arena_state.allocator();

    const readings = [_]c.struct_utrace_clock{
        .{ .clock_id = c.utrace_perfetto_BUILTIN_CLOCK_MONOTONIC, .ts = 100 },
        .{ .clock_id = c.utrace_perfetto_BUILTIN_CLOCK_BOOTTIME, .ts = 150 },
    };
    c.utrace_clock_snapshot(&f.t, &readings, readings.len);
    c.utrace_track(&f.t, 1, 0, "track");
    c.utrace_instant(&f.t, 1, 2000, "now");
    const ps = try f.packets();
    try expectEqual(@as(usize, 4), ps.len);
    for (ps) |p| try expectSequence(p, 9);

    const primary = try ps[0].msg("clock_snapshot");
    try expectEqual(try f.clock("BUILTIN_CLOCK_MONOTONIC"), try primary.int("primary_trace_clock"));
    const primary_clocks = try primary.all(a, "clocks");
    try expectEqual(@as(usize, 1), primary_clocks.len);
    try expectEqual(try f.clock("BUILTIN_CLOCK_MONOTONIC"), try primary_clocks[0].message.int("clock_id"));
    try expectEqual(@as(u64, 0), try primary_clocks[0].message.int("timestamp"));
    try expect(try ps[0].has("first_packet_on_sequence"));

    const snapshot = try ps[1].msg("clock_snapshot");
    try expect(!try snapshot.has("primary_trace_clock"));
    const clocks = try snapshot.all(a, "clocks");
    try expectEqual(@as(usize, 2), clocks.len);
    try expectEqual(try f.clock("BUILTIN_CLOCK_MONOTONIC"), try clocks[0].message.int("clock_id"));
    try expectEqual(@as(u64, 100), try clocks[0].message.int("timestamp"));
    try expectEqual(try f.clock("BUILTIN_CLOCK_BOOTTIME"), try clocks[1].message.int("clock_id"));
    try expectEqual(@as(u64, 150), try clocks[1].message.int("timestamp"));

    try expect(!try ps[2].has("timestamp_clock_id"));
    try expectEqual(@as(u64, 2000), try ps[3].int("timestamp"));
    try expectEqual(try f.clock("BUILTIN_CLOCK_MONOTONIC"), try ps[3].int("timestamp_clock_id"));
}

test "a packet the generated writers fill decodes like the API's own" {
    var f: Fixture = .{ .arena_state = undefined };
    try f.init(null);
    defer f.deinit();

    const w = c.utrace_packet_start_at(&f.t, 10);
    c.utrace_perfetto_TracePacket_begin_track_event(w);
    c.utrace_perfetto_TrackEvent_set_type(w, c.utrace_perfetto_TrackEvent_TYPE_INSTANT);
    c.utrace_perfetto_TrackEvent_set_track_uuid(w, 1);
    c.utrace_perfetto_TrackEvent_set_name_n(w, "raw-ignored", 3);
    c.utrace_pb_end(w);
    c.utrace_packet_finish(&f.t);
    const ps = try f.packets();
    try expectEqual(@as(usize, 1), ps.len);
    try expectEqualStrings("raw", try (try ps[0].msg("track_event")).str("name"));
}

test "an event started inside another fails the trace" {
    var f: Fixture = .{ .arena_state = undefined };
    try f.init(null);
    defer f.deinit();

    c.utrace_event_start(&f.t, c.UTRACE_INSTANT, 1, 1);
    c.utrace_event_start(&f.t, c.UTRACE_INSTANT, 1, 2);
    try expectEqual(@as(c_int, c.UTRACE_PB_EINVAL), c.utrace_error(&f.t));
    try expectEqual(@as(c_int, c.UTRACE_PB_EINVAL), c.utrace_close(&f.t));
}

test "a packet larger than the buffer fails the trace" {
    var f: Fixture = .{ .arena_state = undefined };
    try f.init(null);
    defer f.deinit();

    const long = [_]u8{'x'} ** 5000 ++ [_]u8{0};
    c.utrace_instant(&f.t, 1, 1, &long);
    try expectEqual(@as(c_int, c.UTRACE_PB_ENOSPC), c.utrace_close(&f.t));
}

test "many packets pass through a small buffer" {
    var f: Fixture = .{ .arena_state = undefined };
    try f.init(null);
    defer f.deinit();

    for (0..200) |i| c.utrace_instant(&f.t, 1, i, "tick");
    const ps = try f.packets();
    try expectEqual(@as(usize, 200), ps.len);
    for (ps, 0..) |p, i| try expectEqual(@as(u64, i), try p.int("timestamp"));
}

test "the fd sink writes the same bytes as the memory sink" {
    var f: Fixture = .{ .arena_state = undefined };
    try f.init(null);
    defer f.deinit();
    c.utrace_track(&f.t, 1, 0, "track");
    c.utrace_instant(&f.t, 1, 5, "now");
    try expectEqual(@as(c_int, 0), c.utrace_close(&f.t));

    var fds: [2]c_int = undefined;
    try expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    var buf: [256]u8 = undefined;
    var t: c.struct_utrace = undefined;
    try expectEqual(@as(c_int, 0), c.utrace_open(&t, &buf, buf.len, c.utrace_pb_fd_sink(&fds[1]), null));
    c.utrace_track(&t, 1, 0, "track");
    c.utrace_instant(&t, 1, 5, "now");
    try expectEqual(@as(c_int, 0), c.utrace_close(&t));
    _ = c.close(fds[1]);

    var got: [16384]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const r = c.read(fds[0], &got[n], got.len - n);
        try expect(r >= 0);
        if (r == 0) break;
        n += @intCast(r);
    }
    try std.testing.expectEqualSlices(u8, f.out[0..f.mem.len], got[0..n]);
}

test "an fd sink reports write errors" {
    var buf: [256]u8 = undefined;
    var fd: c_int = -1;
    var t: c.struct_utrace = undefined;
    _ = c.utrace_open(&t, &buf, buf.len, c.utrace_pb_fd_sink(&fd), null);
    c.utrace_instant(&t, 1, 5, "now");
    try expectEqual(-@as(c_int, @intFromEnum(std.posix.E.BADF)), c.utrace_close(&t));
}

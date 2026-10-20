// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause

//! examples/gpu_queues.c's trace, as zig build test ran it, read back against Perfetto's
//! descriptors. zig build tp checks what trace_processor makes of the same file.

const std = @import("std");
const pb = @import("pb");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "the example's trace is well-formed and every flow has both ends" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const set = try pb.DescriptorSet.parse(arena, @embedFile("perfetto.pb"));

    const trace = try pb.Message.decode(arena, set, set.message("perfetto.protos.Trace").?, @embedFile("gpu_queues.pftrace"));
    const packets = try trace.all(arena, "packet");
    // two clock snapshots, six tracks, and per kernel two slices, their ends and two counters
    try expectEqual(@as(usize, 2 + 6 + 4 * 6 + 1), packets.len);

    const monotonic = for (set.enumType("perfetto.protos.BuiltinClock").?.values) |v| {
        if (std.mem.eql(u8, v.name, "BUILTIN_CLOCK_MONOTONIC")) break @as(u64, @intCast(v.number));
    } else return error.NoSuchValue;

    var starts: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var ends: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (packets) |v| {
        const p = v.message;
        try expectEqual(@as(u64, 1), try p.int("trusted_packet_sequence_id"));
        if (!try p.has("track_event")) continue;
        try expectEqual(monotonic, try p.int("timestamp_clock_id"));
        const e = try p.msg("track_event");
        for (try e.all(arena, "flow_ids")) |id| try starts.put(arena, id.int, {});
        for (try e.all(arena, "terminating_flow_ids")) |id| try ends.put(arena, id.int, {});
    }
    try expectEqual(@as(usize, 4), starts.count());
    var it = starts.keyIterator();
    while (it.next()) |id| try expect(ends.contains(id.*));
    try expectEqual(starts.count(), ends.count());
}

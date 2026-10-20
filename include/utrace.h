/*
 * SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */
/**
 * @file utrace.h
 * @brief Perfetto traces from C: tracks, slices, instants, counters, flows and arguments
 *
 * A trace is a stream of packets written to a sink. Declare each track once, with a uuid of the
 * caller's choosing, then write events on it. Nothing is interned and no state is incremental,
 * so every packet stands on its own, and traces written to one file one after another, with
 * different sequence ids, load as one.
 *
 * Timestamps are nanoseconds on the clock given at utrace_open(); the caller reads the clock.
 * Slices on one track must nest: an end closes the most recent begin on that track.
 *
 * A struct utrace is not thread-safe; give each thread its own, with its own sequence id, or
 * serialize the calls.
 */
#ifndef UTRACE_H
#define UTRACE_H

#include <utrace_pb.h>
#include <utrace/perfetto/builtin_clock.h>
#include <utrace/perfetto/clock_snapshot.h>
#include <utrace/perfetto/counter_descriptor.h>
#include <utrace/perfetto/debug_annotation.h>
#include <utrace/perfetto/process_descriptor.h>
#include <utrace/perfetto/thread_descriptor.h>
#include <utrace/perfetto/trace.h>
#include <utrace/perfetto/trace_packet.h>
#include <utrace/perfetto/track_descriptor.h>
#include <utrace/perfetto/track_event.h>

#ifdef __cplusplus
extern "C" {
#endif

enum utrace_event_type {
	UTRACE_SLICE_BEGIN = utrace_perfetto_TrackEvent_TYPE_SLICE_BEGIN,
	UTRACE_SLICE_END   = utrace_perfetto_TrackEvent_TYPE_SLICE_END,
	UTRACE_INSTANT     = utrace_perfetto_TrackEvent_TYPE_INSTANT,
	UTRACE_COUNTER     = utrace_perfetto_TrackEvent_TYPE_COUNTER,
};

struct utrace_opts {
	/**
	 * A BuiltinClock value, e.g. utrace_perfetto_BUILTIN_CLOCK_MONOTONIC; 0 means
	 * BUILTIN_CLOCK_BOOTTIME, which Perfetto takes as the trace's clock when none is named
	 */
	uint32_t clock_id;
	/** Tells this trace's packets from those of other writers to the same file; 0 means 1 */
	uint32_t sequence_id;
};

struct utrace {
	struct utrace_pb_writer w;
	uint32_t clock_id;
	uint32_t sequence_id;
	int started; ///< whether the first packet on the sequence is written
};

static inline int
utrace_error(const struct utrace *t)
{
	return utrace_pb_error(&t->w);
}

/**
 * Opens a packet on the trace's sequence and returns the writer, positioned inside it, for
 * any TracePacket field the generated writers in utrace/perfetto/ can add. Close it with
 * utrace_packet_finish().
 */
static inline struct utrace_pb_writer *
utrace_packet_start(struct utrace *t)
{
	struct utrace_pb_writer *w = &t->w;

	if (w->depth) {
		utrace_pb_fail(w, UTRACE_PB_EINVAL);
	}
	utrace_perfetto_Trace_begin_packet(w);
	utrace_perfetto_TracePacket_set_trusted_packet_sequence_id(w, t->sequence_id);
	if (!t->started) {
		utrace_perfetto_TracePacket_set_sequence_flags(
			w, utrace_perfetto_TracePacket_SEQ_INCREMENTAL_STATE_CLEARED);
		utrace_perfetto_TracePacket_set_first_packet_on_sequence(w, 1);
		t->started = 1;
	}
	return w;
}

/** As utrace_packet_start(), with a timestamp on the trace's clock */
static inline struct utrace_pb_writer *
utrace_packet_start_at(struct utrace *t, uint64_t ts)
{
	struct utrace_pb_writer *w = utrace_packet_start(t);

	utrace_perfetto_TracePacket_set_timestamp(w, ts);
	if (t->clock_id != utrace_perfetto_BUILTIN_CLOCK_BOOTTIME) {
		utrace_perfetto_TracePacket_set_timestamp_clock_id(w, t->clock_id);
	}
	return w;
}

static inline void
utrace_packet_finish(struct utrace *t)
{
	utrace_pb_end(&t->w);
}

/**
 * Starts a trace written through buf, of cap bytes, to sink; each packet must fit in half of
 * buf. opts may be NULL. On a clock other than BOOTTIME, the first packet is a clock snapshot
 * naming it the trace's clock. Returns the writer's error.
 */
static inline int
utrace_open(struct utrace *t, uint8_t *buf, size_t cap, struct utrace_pb_sink sink,
	    const struct utrace_opts *opts)
{
	utrace_pb_init(&t->w, buf, cap, sink);
	t->clock_id    = utrace_perfetto_BUILTIN_CLOCK_BOOTTIME;
	t->sequence_id = 1;
	t->started     = 0;
	if (opts && opts->clock_id) {
		t->clock_id = opts->clock_id;
	}
	if (opts && opts->sequence_id) {
		t->sequence_id = opts->sequence_id;
	}

	if (t->clock_id != utrace_perfetto_BUILTIN_CLOCK_BOOTTIME) {
		struct utrace_pb_writer *w = utrace_packet_start(t);

		utrace_perfetto_TracePacket_begin_clock_snapshot(w);
		utrace_perfetto_ClockSnapshot_begin_clocks(w);
		utrace_perfetto_ClockSnapshot_Clock_set_clock_id(w, t->clock_id);
		utrace_perfetto_ClockSnapshot_Clock_set_timestamp(w, 0);
		utrace_pb_end(w);
		utrace_perfetto_ClockSnapshot_set_primary_trace_clock(w, (int32_t)t->clock_id);
		utrace_pb_end(w);
		utrace_packet_finish(t);
	}
	return utrace_error(t);
}

/** Writes out what is buffered; returns the first error the trace met, or 0 */
static inline int
utrace_close(struct utrace *t)
{
	return utrace_pb_flush(&t->w);
}

/** One clock's reading */
struct utrace_clock {
	uint32_t clock_id; ///< a BuiltinClock value, as in struct utrace_opts
	uint64_t ts;
};

/**
 * Records that n clocks read the given timestamps at one moment, so Perfetto can relate them.
 * On a clock other than BOOTTIME, trace_processor reports BOOTTIME as unrelatable to the
 * trace's clock until a snapshot holds both.
 */
static inline void
utrace_clock_snapshot(struct utrace *t, const struct utrace_clock *clocks, size_t n)
{
	struct utrace_pb_writer *w = utrace_packet_start(t);
	size_t i;

	utrace_perfetto_TracePacket_begin_clock_snapshot(w);
	for (i = 0; i < n; ++i) {
		utrace_perfetto_ClockSnapshot_begin_clocks(w);
		utrace_perfetto_ClockSnapshot_Clock_set_clock_id(w, clocks[i].clock_id);
		utrace_perfetto_ClockSnapshot_Clock_set_timestamp(w, clocks[i].ts);
		utrace_pb_end(w);
	}
	utrace_pb_end(w);
	utrace_packet_finish(t);
}

static inline struct utrace_pb_writer *
utrace_track_start(struct utrace *t, uint64_t uuid, uint64_t parent)
{
	struct utrace_pb_writer *w = utrace_packet_start(t);

	utrace_perfetto_TracePacket_begin_track_descriptor(w);
	utrace_perfetto_TrackDescriptor_set_uuid(w, uuid);
	if (parent) {
		utrace_perfetto_TrackDescriptor_set_parent_uuid(w, parent);
	}
	return w;
}

static inline void
utrace_track_finish(struct utrace *t)
{
	utrace_pb_end(&t->w);
	utrace_packet_finish(t);
}

/** Declares a process; its uuid can parent other tracks */
static inline void
utrace_track_process(struct utrace *t, uint64_t uuid, int32_t pid, const char *name)
{
	struct utrace_pb_writer *w = utrace_track_start(t, uuid, 0);

	utrace_perfetto_TrackDescriptor_begin_process(w);
	utrace_perfetto_ProcessDescriptor_set_pid(w, pid);
	utrace_perfetto_ProcessDescriptor_set_process_name(w, name);
	utrace_pb_end(w);
	utrace_track_finish(t);
}

/** Declares a thread; Perfetto places it under the process of the same pid */
static inline void
utrace_track_thread(struct utrace *t, uint64_t uuid, int32_t pid, int64_t tid, const char *name)
{
	struct utrace_pb_writer *w = utrace_track_start(t, uuid, 0);

	utrace_perfetto_TrackDescriptor_begin_thread(w);
	utrace_perfetto_ThreadDescriptor_set_pid(w, pid);
	utrace_perfetto_ThreadDescriptor_set_tid(w, tid);
	utrace_perfetto_ThreadDescriptor_set_thread_name(w, name);
	utrace_pb_end(w);
	utrace_track_finish(t);
}

/** Declares a track of slices and instants, under parent, or at top level when parent is 0 */
static inline void
utrace_track(struct utrace *t, uint64_t uuid, uint64_t parent, const char *name)
{
	struct utrace_pb_writer *w = utrace_track_start(t, uuid, parent);

	utrace_perfetto_TrackDescriptor_set_name(w, name);
	utrace_track_finish(t);
}

/** Declares a counter track; unit may be NULL */
static inline void
utrace_track_counter(struct utrace *t, uint64_t uuid, uint64_t parent, const char *name,
		     const char *unit)
{
	struct utrace_pb_writer *w = utrace_track_start(t, uuid, parent);

	utrace_perfetto_TrackDescriptor_set_name(w, name);
	utrace_perfetto_TrackDescriptor_begin_counter(w);
	if (unit) {
		utrace_perfetto_CounterDescriptor_set_unit_name(w, unit);
	}
	utrace_pb_end(w);
	utrace_track_finish(t);
}

/**
 * Starts an event of the given type on track at ts. Until utrace_event_finish(), the
 * utrace_event_*() calls below add to it, in any order.
 */
static inline void
utrace_event_start(struct utrace *t, enum utrace_event_type type, uint64_t track, uint64_t ts)
{
	struct utrace_pb_writer *w = utrace_packet_start_at(t, ts);

	utrace_perfetto_TracePacket_begin_track_event(w);
	utrace_perfetto_TrackEvent_set_type(w, (int32_t)type);
	utrace_perfetto_TrackEvent_set_track_uuid(w, track);
}

static inline void
utrace_event_finish(struct utrace *t)
{
	utrace_pb_end(&t->w);
	utrace_packet_finish(t);
}

static inline void
utrace_event_name(struct utrace *t, const char *name)
{
	utrace_perfetto_TrackEvent_set_name(&t->w, name);
}

static inline void
utrace_event_category(struct utrace *t, const char *category)
{
	utrace_perfetto_TrackEvent_add_categories(&t->w, category);
}

/** Links this event to the next event naming the same flow id */
static inline void
utrace_event_flow(struct utrace *t, uint64_t id)
{
	utrace_perfetto_TrackEvent_add_flow_ids(&t->w, id);
}

/** Links this event to the previous event naming the same flow id, and ends the flow */
static inline void
utrace_event_flow_end(struct utrace *t, uint64_t id)
{
	utrace_perfetto_TrackEvent_add_terminating_flow_ids(&t->w, id);
}

/** The value of a UTRACE_COUNTER event */
static inline void
utrace_event_value(struct utrace *t, int64_t value)
{
	utrace_perfetto_TrackEvent_set_counter_value(&t->w, value);
}

static inline void
utrace_event_value_double(struct utrace *t, double value)
{
	utrace_perfetto_TrackEvent_set_double_counter_value(&t->w, value);
}

static inline struct utrace_pb_writer *
utrace_arg_start(struct utrace *t, const char *name)
{
	struct utrace_pb_writer *w = &t->w;

	utrace_perfetto_TrackEvent_begin_debug_annotations(w);
	utrace_perfetto_DebugAnnotation_set_name(w, name);
	return w;
}

static inline void
utrace_event_arg_int(struct utrace *t, const char *name, int64_t value)
{
	utrace_perfetto_DebugAnnotation_set_int_value(utrace_arg_start(t, name), value);
	utrace_pb_end(&t->w);
}

static inline void
utrace_event_arg_uint(struct utrace *t, const char *name, uint64_t value)
{
	utrace_perfetto_DebugAnnotation_set_uint_value(utrace_arg_start(t, name), value);
	utrace_pb_end(&t->w);
}

static inline void
utrace_event_arg_double(struct utrace *t, const char *name, double value)
{
	utrace_perfetto_DebugAnnotation_set_double_value(utrace_arg_start(t, name), value);
	utrace_pb_end(&t->w);
}

static inline void
utrace_event_arg_bool(struct utrace *t, const char *name, int value)
{
	utrace_perfetto_DebugAnnotation_set_bool_value(utrace_arg_start(t, name), value);
	utrace_pb_end(&t->w);
}

static inline void
utrace_event_arg_str(struct utrace *t, const char *name, const char *value)
{
	utrace_perfetto_DebugAnnotation_set_string_value(utrace_arg_start(t, name), value);
	utrace_pb_end(&t->w);
}

static inline void
utrace_slice_begin(struct utrace *t, uint64_t track, uint64_t ts, const char *name)
{
	utrace_event_start(t, UTRACE_SLICE_BEGIN, track, ts);
	utrace_event_name(t, name);
	utrace_event_finish(t);
}

/** Ends the most recent slice begun on track */
static inline void
utrace_slice_end(struct utrace *t, uint64_t track, uint64_t ts)
{
	utrace_event_start(t, UTRACE_SLICE_END, track, ts);
	utrace_event_finish(t);
}

static inline void
utrace_instant(struct utrace *t, uint64_t track, uint64_t ts, const char *name)
{
	utrace_event_start(t, UTRACE_INSTANT, track, ts);
	utrace_event_name(t, name);
	utrace_event_finish(t);
}

static inline void
utrace_counter(struct utrace *t, uint64_t track, uint64_t ts, int64_t value)
{
	utrace_event_start(t, UTRACE_COUNTER, track, ts);
	utrace_event_value(t, value);
	utrace_event_finish(t);
}

static inline void
utrace_counter_double(struct utrace *t, uint64_t track, uint64_t ts, double value)
{
	utrace_event_start(t, UTRACE_COUNTER, track, ts);
	utrace_event_value_double(t, value);
	utrace_event_finish(t);
}

#ifdef __cplusplus
}
#endif

#endif /* UTRACE_H */

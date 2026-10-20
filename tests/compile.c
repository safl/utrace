/*
 * SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */
/*
 * Compiled as C99, C11, C17, C++11, C++17 and C++20 with warnings as errors, so every header is
 * held to each of them. The function calls what a header defines, so its bodies are instantiated.
 */
#include <utrace_pb.h>
#include <utrace.h>
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

int
utrace_compile_check(void);

int
utrace_compile_check(void)
{
	uint8_t buf[256];
	uint8_t out[256];
	struct utrace_pb_mem mem = {out, sizeof(out), 0};
	struct utrace_pb_writer w;

	utrace_pb_init(&w, buf, sizeof(buf), utrace_pb_mem_sink(&mem));
	utrace_pb_begin(&w, 1);
	utrace_pb_field_varint(&w, 1, 1);
	utrace_pb_field_sint(&w, 2, -1);
	utrace_pb_field_fixed64(&w, 3, 1);
	utrace_pb_field_fixed32(&w, 4, 1);
	utrace_pb_field_double(&w, 5, 1.0);
	utrace_pb_field_float(&w, 6, 1.0f);
	utrace_pb_field_string(&w, 7, "x");
	utrace_pb_field_bytes(&w, 8, "x", 1);
	utrace_pb_end(&w);
	return utrace_pb_flush(&w);
}

int
utrace_compile_check_api(void);

int
utrace_compile_check_api(void)
{
	uint8_t buf[1024];
	uint8_t out[1024];
	struct utrace_pb_mem mem = {out, sizeof(out), 0};
	struct utrace_clock clocks[1];
	struct utrace_opts opts;
	struct utrace t;

	opts.clock_id      = utrace_perfetto_BUILTIN_CLOCK_MONOTONIC;
	opts.sequence_id   = 2;
	clocks[0].clock_id = utrace_perfetto_BUILTIN_CLOCK_BOOTTIME;
	clocks[0].ts       = 1;

	utrace_open(&t, buf, sizeof(buf), utrace_pb_mem_sink(&mem), &opts);
	utrace_clock_snapshot(&t, clocks, 1);
	utrace_track_process(&t, 1, 1, "p");
	utrace_track_thread(&t, 2, 1, 1, "t");
	utrace_track(&t, 3, 1, "d");
	utrace_track_counter(&t, 4, 3, "c", "u");
	utrace_event_start(&t, UTRACE_SLICE_BEGIN, 2, 1);
	utrace_event_name(&t, "s");
	utrace_event_category(&t, "c");
	utrace_event_flow(&t, 1);
	utrace_event_flow_end(&t, 2);
	utrace_event_arg_int(&t, "i", -1);
	utrace_event_arg_uint(&t, "u", 1);
	utrace_event_arg_double(&t, "d", 1.0);
	utrace_event_arg_bool(&t, "b", 1);
	utrace_event_arg_str(&t, "s", "s");
	utrace_event_finish(&t);
	utrace_slice_end(&t, 2, 2);
	utrace_slice_begin(&t, 3, 3, "k");
	utrace_slice_end(&t, 3, 4);
	utrace_instant(&t, 2, 5, "i");
	utrace_counter(&t, 4, 6, 1);
	utrace_counter_double(&t, 4, 7, 1.0);
	(void)utrace_packet_start_at(&t, 8);
	utrace_packet_finish(&t);
	return utrace_close(&t);
}

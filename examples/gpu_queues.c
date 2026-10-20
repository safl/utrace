/*
 * SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */
/*
 * Writes the trace a GPU stack might: a host thread submitting kernels to two queues of one
 * device, each submit linked by a flow to the kernel it started, and a counter of the kernels
 * in flight. The timeline is made up and fixed, so the output is the same on every host.
 *
 * usage: gpu_queues <trace file>
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <utrace.h>

enum {
	PID = 4242,

	PROCESS  = 1,
	HOST     = 2,
	DEVICE   = 3,
	QUEUE0   = 4,
	QUEUE1   = 5,
	INFLIGHT = 6,
};

/* Each queue runs one kernel at a time; the two queues overlap */
static const struct kernel {
	uint64_t queue;
	uint64_t submit, start, end;
} kernels[] = {
	{QUEUE0, 1000, 1100, 1900},
	{QUEUE1, 1400, 1500, 2300},
	{QUEUE0, 1800, 1900, 2700},
	{QUEUE1, 2200, 2300, 3100},
};

#define NKERNELS ((int)(sizeof(kernels) / sizeof(kernels[0])))

static int64_t
running(uint64_t ts)
{
	int64_t n = 0;
	int i;

	for (i = 0; i < NKERNELS; ++i) {
		n += kernels[i].start <= ts && ts < kernels[i].end;
	}
	return n;
}

int
main(int argc, char **argv)
{
	static uint8_t buf[1 << 16];
	struct utrace_clock clocks[2];
	struct utrace_opts opts;
	struct utrace t;
	int fd, err, i;

	if (argc != 2) {
		fprintf(stderr, "usage: %s <trace file>\n", argv[0]);
		return 2;
	}
	fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}

	memset(&opts, 0, sizeof(opts));
	opts.clock_id = utrace_perfetto_BUILTIN_CLOCK_MONOTONIC;
	utrace_open(&t, buf, sizeof(buf), utrace_pb_fd_sink(&fd), &opts);

	/* a real program reads both clocks with clock_gettime(), back to back */
	clocks[0].clock_id = utrace_perfetto_BUILTIN_CLOCK_MONOTONIC;
	clocks[0].ts       = 0;
	clocks[1].clock_id = utrace_perfetto_BUILTIN_CLOCK_BOOTTIME;
	clocks[1].ts       = 0;
	utrace_clock_snapshot(&t, clocks, 2);

	utrace_track_process(&t, PROCESS, PID, "gpu_queues");
	utrace_track_thread(&t, HOST, PID, PID, "host");
	utrace_track(&t, DEVICE, PROCESS, "gpu0");
	utrace_track(&t, QUEUE0, DEVICE, "queue0");
	utrace_track(&t, QUEUE1, DEVICE, "queue1");
	utrace_track_counter(&t, INFLIGHT, DEVICE, "inflight", "kernels");

	for (i = 0; i < NKERNELS; ++i) {
		const struct kernel *k = &kernels[i];
		uint64_t flow          = 100 + (uint64_t)i;

		utrace_event_start(&t, UTRACE_SLICE_BEGIN, HOST, k->submit);
		utrace_event_name(&t, "submit");
		utrace_event_category(&t, "host");
		utrace_event_flow(&t, flow);
		utrace_event_arg_int(&t, "kernel", i);
		utrace_event_arg_str(&t, "queue", k->queue == QUEUE0 ? "queue0" : "queue1");
		utrace_event_finish(&t);
		utrace_slice_end(&t, HOST, k->submit + 50);

		utrace_event_start(&t, UTRACE_SLICE_BEGIN, k->queue, k->start);
		utrace_event_name(&t, "kernel");
		utrace_event_category(&t, "gpu");
		utrace_event_flow_end(&t, flow);
		utrace_event_arg_uint(&t, "grid", 64u << i);
		utrace_event_finish(&t);
		utrace_slice_end(&t, k->queue, k->end);

		utrace_counter(&t, INFLIGHT, k->start, running(k->start));
		utrace_counter(&t, INFLIGHT, k->end, running(k->end));
	}
	utrace_instant(&t, HOST, kernels[NKERNELS - 1].end, "sync");

	err = utrace_close(&t);
	if (close(fd) && !err) {
		err = -1;
	}
	if (err) {
		fprintf(stderr, "%s: writing the trace failed: %d\n", argv[1], err);
		return 1;
	}
	return 0;
}

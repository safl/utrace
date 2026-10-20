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

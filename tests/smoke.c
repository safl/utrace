/*
 * SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */
/*
 * Runs what tests/compile.c instantiates, so each standard's build is also executed, and so the
 * sanitizer builds have something to watch
 */
#include <stdio.h>

int
utrace_compile_check(void);

int
utrace_compile_check_api(void);

int
main(void)
{
	int err;

	err = utrace_compile_check();
	if (err) {
		fprintf(stderr, "utrace_compile_check(): %d\n", err);
		return 1;
	}
	err = utrace_compile_check_api();
	if (err) {
		fprintf(stderr, "utrace_compile_check_api(): %d\n", err);
		return 1;
	}
	return 0;
}

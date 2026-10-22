# SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
#
# SPDX-License-Identifier: BSD-3-Clause
#
# A consumer of uTrace, built by tests/meson/check.sh twice: against an
# installed uTrace through its utrace.pc, and through a wrap of the checkout.
project('utrace-consumer', 'c', default_options: ['c_std=c99', 'warning_level=3', 'werror=true'])

executable('gpu_queues', '../../examples/gpu_queues.c', dependencies: dependency('utrace'))

# SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
#
# SPDX-License-Identifier: BSD-3-Clause
#
# For Meson consumers and packagers; zig build stays the development build.
# There is nothing to compile: as a subproject this declares the headers,
# and installed it puts them and a utrace.pc in place. The version matches
# build.zig.zon's, which CI checks.
project('utrace', 'c', version: '0.1.0', license: 'BSD-3-Clause AND Apache-2.0', meson_version: '>=1.1')

utrace_dep = declare_dependency(include_directories: include_directories('include'))
meson.override_dependency('utrace', utrace_dep)

install_subdir('include', install_dir: get_option('includedir'), strip_directory: true)
install_data('LICENSES/BSD-3-Clause.txt', 'LICENSES/Apache-2.0.txt', install_dir: get_option('datadir') / 'licenses' / 'utrace')

import('pkgconfig').generate(name: 'utrace', description: 'Perfetto traces from C, header-only',
  url: 'https://github.com/safl/utrace')

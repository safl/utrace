#!/bin/sh
# SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
#
# SPDX-License-Identifier: BSD-3-Clause
#
# Checks uTrace's meson.build the two ways a Meson project takes it: installed,
# found through utrace.pc, and fetched by a wrap-git of this checkout's HEAD.
# Each builds the example as a consumer and runs it; the wrapped build must
# install uTrace by default and nothing with skip-install=true. Run from the
# repository's top; needs meson, ninja, pkg-config, a C compiler and git.
set -eu

top=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

zon=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
mes=$(meson introspect --projectinfo meson.build | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
[ "$zon" = "$mes" ] || { echo "meson.build has version $mes, build.zig.zon $zon" >&2; exit 1; }

# installed: headers, licences and a utrace.pc with no Libs
meson setup --prefix="$tmp/usr" "$tmp/b" > /dev/null
meson install -C "$tmp/b" > /dev/null
pc=$(find "$tmp/usr" -name utrace.pc)
test -n "$pc"
test -f "$tmp/usr/include/utrace.h"
test -f "$tmp/usr/include/utrace/perfetto/track_event.h"
test -f "$tmp/usr/share/licenses/utrace/Apache-2.0.txt"
if grep -q '^Libs:.*-l' "$pc"; then echo "utrace.pc links a library" >&2; exit 1; fi
PKG_CONFIG_PATH=$(dirname "$pc") meson setup --wrap-mode=nofallback "$tmp/c1" tests/meson > /dev/null
ninja -C "$tmp/c1" > /dev/null
(cd "$tmp" && ./c1/gpu_queues c1.pftrace > /dev/null && test -s c1.pftrace)

# a wrap: the consumer's subprojects/utrace.wrap, as the README shows it
mkdir -p "$tmp/w/subprojects"
mkdir -p "$tmp/examples" && cp examples/gpu_queues.c "$tmp/examples/"
sed "s|^executable.*|executable('gpu_queues', '../examples/gpu_queues.c', dependencies: dependency('utrace'))|" tests/meson/meson.build > "$tmp/w/meson.build"
cat > "$tmp/w/subprojects/utrace.wrap" << WRAP
[wrap-git]
url = $top
revision = $(git rev-parse HEAD)
depth = 1

[provide]
dependency_names = utrace
WRAP
PKG_CONFIG_PATH= meson setup --wrap-mode=forcefallback "$tmp/c2" "$tmp/w" > /dev/null
ninja -C "$tmp/c2" > /dev/null
(cd "$tmp" && ./c2/gpu_queues c2.pftrace > /dev/null && test -s c2.pftrace)
DESTDIR="$tmp/c2-dest" meson install -C "$tmp/c2" > /dev/null
for f in utrace.h utrace/perfetto/track_event.h licenses/utrace/Apache-2.0.txt utrace.pc; do
	if [ -z "$(find "$tmp/c2-dest" -path "*/$f")" ]; then
		echo "a wrapped uTrace did not install $f" >&2
		exit 1
	fi
done

meson configure -Dutrace:skip-install=true "$tmp/c2" > /dev/null
DESTDIR="$tmp/c2-skip" meson install -C "$tmp/c2" > /dev/null
if [ -n "$(find "$tmp/c2-skip" -path '*utrace*' 2> /dev/null)" ]; then
	echo "a wrapped uTrace installed with skip-install=true" >&2
	exit 1
fi
echo "meson: installed and wrapped consumers built and ran"

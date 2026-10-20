#!/usr/bin/env bash
# SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
#
# SPDX-License-Identifier: BSD-3-Clause
#
# Replaces third-party/perfetto/protos with the given Perfetto release's
# protos/perfetto/trace/trace.proto and every file it imports, unmodified.
# Usage: tools/vendor-perfetto.sh v58.2
set -euo pipefail

tag="${1:?usage: $0 <perfetto release tag>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/third-party/perfetto"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" \
	--filter=blob:none --sparse https://github.com/google/perfetto.git "$work/perfetto"
git -C "$work/perfetto" sparse-checkout set protos
commit="$(git -C "$work/perfetto" rev-parse HEAD)"

declare -A seen
todo=(protos/perfetto/trace/trace.proto)
while ((${#todo[@]})); do
	file="${todo[0]}"
	todo=("${todo[@]:1}")
	[[ -n "${seen[$file]:-}" ]] && continue
	seen[$file]=1
	while read -r dep; do
		todo+=("$dep")
	done < <(sed -n 's/^import "\(.*\)";$/\1/p' "$work/perfetto/$file")
done

if [[ -d "$dest/protos" ]]; then
	git -C "$root" rm -rq --ignore-unmatch -- third-party/perfetto/protos
fi
for file in "${!seen[@]}"; do
	mkdir -p "$dest/$(dirname "$file")"
	cp "$work/perfetto/$file" "$dest/$file"
done
printf '%s %s\n' "$tag" "$commit" > "$dest/VERSION"
echo "vendored ${#seen[@]} files of Perfetto $tag ($commit)"

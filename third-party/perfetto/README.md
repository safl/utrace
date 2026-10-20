<!--
SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>

SPDX-License-Identifier: BSD-3-Clause
-->

# Perfetto protos

`protos/` holds `protos/perfetto/trace/trace.proto` and every file it
imports, copied unmodified from <https://github.com/google/perfetto> at the
release named in `VERSION`, with the commit that release points at. They are
Apache-2.0, as upstream licenses them (`LICENSES/Apache-2.0.txt`).

`tools/gen` takes every field number and enum value in
`include/utrace/perfetto/` from these files. To move to another release:

```sh
tools/vendor-perfetto.sh v58.2
zig build gen
```

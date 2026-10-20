<!--
SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>

SPDX-License-Identifier: BSD-3-Clause
-->

# protobuf's descriptor.proto

`google/protobuf/descriptor.proto` is copied unmodified from
<https://github.com/protocolbuffers/protobuf> at release v21.12 (commit
f0dc78d7e6e331b8c6bb2d5283e06aa26883ca7c), from `src/google/protobuf/`. It is
BSD-3-Clause, as upstream licenses it.

`tools/pb.zig` decodes protoc's FileDescriptorSet with field numbers of its
own; `tests/descriptor_test.zig` checks each of them against this file.

# uTrace

uTrace writes [Perfetto](https://perfetto.dev) traces from C and C++. It is a
handful of headers: include them, point a trace at a file descriptor, a
memory buffer or a callback, and write tracks, slices, instants, counters and
flows. The result opens in the Perfetto UI and in `trace_processor`.

It exists so that GPU runtimes can profile their queues, and so that xNVMe can later
put NVMe activity into the same trace.

## Why another encoder

Perfetto traces are protobuf. No existing encoder fits a C library that wants
to stay header-only and dependency-free. protozero and protopuf are C++.
nanopb and protobuf-c need a code generator at build time and are not
header-only. Perfetto's C SDK needs its shared library, and its API is not yet
stable.

uTrace generates its writers ahead of time from Perfetto's own `.proto` files
and commits the result. A consumer needs a C99 or C++11 compiler and nothing
else.

## Non-goals

uTrace writes traces. It does not read them back, it does not intern strings
or keep incremental state, and it does not record anything by itself: the
caller says what happened and when.

## Using it

Add `include/` to the include path. Everything is `static inline`; there is
nothing to build or link.

```c
#include <utrace.h>

static uint8_t buf[1 << 16];
struct utrace t;
int fd = open("gpu.pftrace", O_WRONLY | O_CREAT | O_TRUNC, 0644);

utrace_open(&t, buf, sizeof(buf), utrace_pb_fd_sink(&fd), NULL);

utrace_track_process(&t, 1, getpid(), "app");
utrace_track_thread(&t, 2, getpid(), gettid(), "host");
utrace_track(&t, 3, 1, "gpu0");            /* a device in the process */
utrace_track(&t, 4, 3, "queue0");          /* a queue of the device */
utrace_track_counter(&t, 5, 3, "inflight", "kernels");

utrace_event_start(&t, UTRACE_SLICE_BEGIN, 2, t0);
utrace_event_name(&t, "submit");
utrace_event_flow(&t, 42);                 /* to the kernel below */
utrace_event_arg_int(&t, "bytes", 4096);
utrace_event_finish(&t);
utrace_slice_end(&t, 2, t1);

utrace_event_start(&t, UTRACE_SLICE_BEGIN, 4, t2);
utrace_event_name(&t, "kernel");
utrace_event_flow_end(&t, 42);
utrace_event_finish(&t);
utrace_slice_end(&t, 4, t3);
utrace_counter(&t, 5, t2, 1);

int err = utrace_close(&t); /* the first error the trace met, or 0 */
```

`examples/gpu_queues.c` is the whole of that as a program. Track uuids are
the caller's choice and must not be 0. Slices on one track must nest.
`utrace_slice_begin()`, `utrace_instant()` and `utrace_counter()` are
shorthands for an event with nothing but a name or a value.

Timestamps are nanoseconds on one clock per trace, `BOOTTIME` unless
`struct utrace_opts` names another. On another clock, `trace_processor` also
wants to relate it to `BOOTTIME`; `utrace_clock_snapshot()` records readings
of both.

Each packet is encoded into the caller's buffer and must fit in half of it.
The buffer goes to the sink once it is half full and at `utrace_close()`.
Errors stick: check `utrace_close()`, or `utrace_error()` along the way.
A `struct utrace` is not thread-safe. Give each thread its own, with its own
`sequence_id`; traces written one after another to one file load as one.

For anything the API does not cover, `utrace_packet_start()` returns the
writer inside a fresh `TracePacket`, and the generated writers in
`include/utrace/perfetto/` add any of Perfetto's fields:

```c
struct utrace_pb_writer *w = utrace_packet_start_at(&t, ts);

utrace_perfetto_TracePacket_begin_track_event(w);
utrace_perfetto_TrackEvent_set_type(w, utrace_perfetto_TrackEvent_TYPE_INSTANT);
utrace_perfetto_TrackEvent_set_track_uuid(w, 4);
utrace_perfetto_TrackEvent_set_name(w, "doorbell");
utrace_pb_end(w);
utrace_packet_finish(&t);
```

### With Meson

uTrace has a `meson.build` for Meson projects and packagers; it compiles
nothing. A project takes it with `dependency('utrace')`, which finds an
installed uTrace through its `utrace.pc`, or falls back to a wrap in the
project's `subprojects/utrace.wrap`:

```ini
[wrap-git]
url = https://github.com/safl/utrace.git
revision = <a commit or tag>
depth = 1

[provide]
dependency_names = utrace
```

`meson install` puts the headers under `include/`, both licences under
`share/licenses/utrace/` and `utrace.pc`, which has `Cflags` and no `Libs`.
As a subproject uTrace installs these into the project's prefix, as Meson
subprojects do; a project that builds against uTrace without shipping it sets
`-Dutrace:skip-install=true`, or `default_options: ['skip-install=true']` on
its `subproject('utrace')` call.

## Layout

```
include/utrace.h             the trace API
include/utrace_pb.h          the protobuf wire runtime and the sinks
include/utrace/perfetto/     writers generated from Perfetto's protos
tools/gen.zig, tools/pb.zig  the generator and the decoder it and the tests share
third-party/perfetto/        Perfetto's protos, unmodified, and the release they are from
third-party/protobuf/        protobuf's descriptor.proto, for the decoder's tests
examples/gpu_queues.c        a host thread, a device and two queues
tests/                       what zig build test, cross, asan and tp run
tests/meson/                 the Meson consumer check, installed and wrapped
meson.build                  for Meson consumers and packagers
```

## Regenerating the writers

`include/utrace/perfetto/` is generated and committed. Every field number and
enum value in it comes from the protos under `third-party/perfetto/`. To move
to another Perfetto release:

```sh
tools/vendor-perfetto.sh v58.2
zig build gen
```

The generator runs `protoc` (any 3.x or later) on the vendored protos and
writes one header per `.proto` file holding the messages listed in
`build.zig`. CI regenerates and fails when the result differs from what is
committed.

## Developing

uTrace builds with Zig 0.16.0. The tests also need `protoc`.

```sh
zig build test                          # every header in C99, C11, C17, C++11, C++17 and C++20, and the tests
zig build test -Dtarget=s390x-linux-musl -fqemu    # the same on big-endian, under qemu
zig build cross -fqemu                  # the example on four architectures, compared byte for byte
zig build asan                          # the system cc and c++ with ASan and UBSan
zig build tp -Dtrace-processor=<trace_processor_shell>   # the example's trace, as Perfetto reads it
tests/meson/check.sh                    # Meson consumers: installed, and through a wrap
pre-commit run --all-files              # whitespace, REUSE, clang-format, zig fmt
```

The tests decode what the C API writes with a separate Zig decoder, by field
name, against `protoc`'s descriptor of the vendored protos. A field written
under the wrong number fails there, rather than being dropped in silence by
Perfetto.

## License

uTrace's own code is BSD-3-Clause. The generated headers carry Perfetto's
message names and field numbers, so they are BSD-3-Clause AND Apache-2.0.
The vendored protos keep their licenses. Each file says which applies, as
[REUSE](https://reuse.software) checks.

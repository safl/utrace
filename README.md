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

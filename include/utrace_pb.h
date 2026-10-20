/*
 * SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */
/**
 * @file utrace_pb.h
 * @brief Protobuf wire encoding into a caller-provided buffer, flushed to a sink
 *
 * The writer encodes one top-level message at a time into a buffer it does not own. A nested
 * message gets a four-byte length prefix when it begins, written as a padded varint and filled
 * in when it ends, so nothing is encoded twice; Perfetto's protozero does the same. When a
 * top-level message ends and the buffer is at least half full, the buffer goes to the sink.
 * Each top-level message must thus fit in half the buffer.
 *
 * Errors are sticky: the first one is kept in the writer, later calls do nothing, and
 * utrace_pb_flush() returns it. Nothing allocates. A writer is not thread-safe.
 */
#ifndef UTRACE_PB_H
#define UTRACE_PB_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if defined(__unix__) || defined(__APPLE__)
#define UTRACE_PB_HAVE_FD_SINK 1
#include <errno.h>
#include <unistd.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

#ifndef UTRACE_PB_MAX_DEPTH
#define UTRACE_PB_MAX_DEPTH 16
#endif

/** Errors, as Linux numbers the errno values they negate */
enum utrace_pb_err {
	UTRACE_PB_OK = 0,
	/** A message did not fit in the buffer, or the memory sink is full */
	UTRACE_PB_ENOSPC = -28,
	/** A nested message is 2^28 bytes or longer */
	UTRACE_PB_EMSGSIZE = -90,
	/** Nesting past UTRACE_PB_MAX_DEPTH, an end without a begin, or a flush inside one */
	UTRACE_PB_EINVAL = -22,
	/** The sink failed; a sink may return a negative value of its own instead */
	UTRACE_PB_EIO = -5,
};

enum utrace_pb_wire_type {
	UTRACE_PB_WIRE_VARINT = 0,
	UTRACE_PB_WIRE_I64    = 1,
	UTRACE_PB_WIRE_LEN    = 2,
	UTRACE_PB_WIRE_I32    = 5,
};

/**
 * Where encoded bytes go: write() consumes all len bytes and returns 0, or returns a negative
 * value, which becomes the writer's error
 */
struct utrace_pb_sink {
	int (*write)(void *ctx, const uint8_t *buf, size_t len);
	void *ctx;
};

struct utrace_pb_writer {
	uint8_t *buf;
	size_t cap;
	size_t len;
	struct utrace_pb_sink sink;
	int err;
	unsigned depth;
	size_t open[UTRACE_PB_MAX_DEPTH]; ///< offset of each open message's length prefix
};

/** The bytes a nested message reserves for its length: a varint padded to four bytes */
#define UTRACE_PB_LEN_PREFIX 4

static inline void
utrace_pb_init(struct utrace_pb_writer *w, uint8_t *buf, size_t cap, struct utrace_pb_sink sink)
{
	w->buf   = buf;
	w->cap   = cap;
	w->len   = 0;
	w->sink  = sink;
	w->err   = UTRACE_PB_OK;
	w->depth = 0;
}

static inline int
utrace_pb_error(const struct utrace_pb_writer *w)
{
	return w->err;
}

static inline void
utrace_pb_fail(struct utrace_pb_writer *w, int err)
{
	if (!w->err) {
		w->err = err;
	}
}

/** Sends whatever is buffered to the sink; returns the writer's error */
static inline int
utrace_pb_flush(struct utrace_pb_writer *w)
{
	if (w->err || !w->len) {
		return w->err;
	}
	if (w->depth) {
		utrace_pb_fail(w, UTRACE_PB_EINVAL);
		return w->err;
	}
	{
		int err = w->sink.write(w->sink.ctx, w->buf, w->len);

		if (err) {
			utrace_pb_fail(w, err < 0 ? err : UTRACE_PB_EIO);
		}
	}
	w->len = 0;
	return w->err;
}

/** Room for n more bytes; on failure the writer holds UTRACE_PB_ENOSPC */
static inline int
utrace_pb_reserve(struct utrace_pb_writer *w, size_t n)
{
	if (w->err) {
		return 0;
	}
	if (w->cap - w->len < n) {
		utrace_pb_fail(w, UTRACE_PB_ENOSPC);
		return 0;
	}
	return 1;
}

static inline void
utrace_pb_raw(struct utrace_pb_writer *w, const void *data, size_t n)
{
	if (!utrace_pb_reserve(w, n)) {
		return;
	}
	if (n) {
		memcpy(w->buf + w->len, data, n);
	}
	w->len += n;
}

static inline size_t
utrace_pb_varint_size(uint64_t v)
{
	size_t n = 1;

	while (v >= 0x80) {
		v >>= 7;
		++n;
	}
	return n;
}

static inline void
utrace_pb_varint(struct utrace_pb_writer *w, uint64_t v)
{
	if (w->err || (w->cap - w->len < 10 && !utrace_pb_reserve(w, utrace_pb_varint_size(v)))) {
		return;
	}
	while (v >= 0x80) {
		w->buf[w->len++] = (uint8_t)(v | 0x80);
		v >>= 7;
	}
	w->buf[w->len++] = (uint8_t)v;
}

/** Little-endian whatever the host's byte order */
static inline void
utrace_pb_le(struct utrace_pb_writer *w, uint64_t v, unsigned nbytes)
{
	unsigned i;

	if (!utrace_pb_reserve(w, nbytes)) {
		return;
	}
	for (i = 0; i < nbytes; ++i) {
		w->buf[w->len++] = (uint8_t)(v >> (8 * i));
	}
}

static inline uint64_t
utrace_pb_zigzag(int64_t v)
{
	return v < 0 ? ~((uint64_t)v << 1) : (uint64_t)v << 1;
}

static inline void
utrace_pb_key(struct utrace_pb_writer *w, uint32_t field, enum utrace_pb_wire_type type)
{
	utrace_pb_varint(w, ((uint64_t)field << 3) | (uint64_t)type);
}

/** For int32, int64, uint32, uint64, bool and enum fields; int32 widens with its sign */
static inline void
utrace_pb_field_varint(struct utrace_pb_writer *w, uint32_t field, uint64_t v)
{
	utrace_pb_key(w, field, UTRACE_PB_WIRE_VARINT);
	utrace_pb_varint(w, v);
}

static inline void
utrace_pb_field_sint(struct utrace_pb_writer *w, uint32_t field, int64_t v)
{
	utrace_pb_field_varint(w, field, utrace_pb_zigzag(v));
}

static inline void
utrace_pb_field_fixed64(struct utrace_pb_writer *w, uint32_t field, uint64_t v)
{
	utrace_pb_key(w, field, UTRACE_PB_WIRE_I64);
	utrace_pb_le(w, v, 8);
}

static inline void
utrace_pb_field_fixed32(struct utrace_pb_writer *w, uint32_t field, uint32_t v)
{
	utrace_pb_key(w, field, UTRACE_PB_WIRE_I32);
	utrace_pb_le(w, v, 4);
}

static inline void
utrace_pb_field_double(struct utrace_pb_writer *w, uint32_t field, double v)
{
	uint64_t bits;

	memcpy(&bits, &v, sizeof(bits));
	utrace_pb_field_fixed64(w, field, bits);
}

static inline void
utrace_pb_field_float(struct utrace_pb_writer *w, uint32_t field, float v)
{
	uint32_t bits;

	memcpy(&bits, &v, sizeof(bits));
	utrace_pb_field_fixed32(w, field, bits);
}

static inline void
utrace_pb_field_bytes(struct utrace_pb_writer *w, uint32_t field, const void *data, size_t n)
{
	utrace_pb_key(w, field, UTRACE_PB_WIRE_LEN);
	utrace_pb_varint(w, n);
	utrace_pb_raw(w, data, n);
}

/** A NULL string is written as an empty one */
static inline void
utrace_pb_field_string(struct utrace_pb_writer *w, uint32_t field, const char *s)
{
	utrace_pb_field_bytes(w, field, s ? s : "", s ? strlen(s) : 0);
}

/**
 * Zig 0.16 mistypes w->open[i] as its translate-c renders it, for the Zig tests; indexing
 * through a plain pointer avoids that
 */
static inline size_t *
utrace_pb_open(struct utrace_pb_writer *w)
{
	return w->open;
}

/**
 * Opens a length-delimited field: a nested message, or a packed repeated field whose elements
 * are written with utrace_pb_varint() or utrace_pb_le(). Close it with utrace_pb_end().
 */
static inline void
utrace_pb_begin(struct utrace_pb_writer *w, uint32_t field)
{
	size_t *open = utrace_pb_open(w);

	if (w->depth >= UTRACE_PB_MAX_DEPTH) {
		utrace_pb_fail(w, UTRACE_PB_EINVAL);
		return;
	}
	utrace_pb_key(w, field, UTRACE_PB_WIRE_LEN);
	if (!utrace_pb_reserve(w, UTRACE_PB_LEN_PREFIX)) {
		return;
	}
	open[w->depth] = w->len;
	w->depth += 1;
	w->len += UTRACE_PB_LEN_PREFIX;
}

/** Closes what utrace_pb_begin() opened; at depth zero a half-full buffer is flushed */
static inline void
utrace_pb_end(struct utrace_pb_writer *w)
{
	size_t *open = utrace_pb_open(w);
	size_t at, n;

	if (w->err) {
		return;
	}
	if (!w->depth) {
		utrace_pb_fail(w, UTRACE_PB_EINVAL);
		return;
	}
	w->depth -= 1;
	at = open[w->depth];
	n  = w->len - at - UTRACE_PB_LEN_PREFIX;
	if (n >= ((size_t)1 << 28)) {
		utrace_pb_fail(w, UTRACE_PB_EMSGSIZE);
		return;
	}
	w->buf[at + 0] = (uint8_t)(n | 0x80);
	w->buf[at + 1] = (uint8_t)((n >> 7) | 0x80);
	w->buf[at + 2] = (uint8_t)((n >> 14) | 0x80);
	w->buf[at + 3] = (uint8_t)(n >> 21);

	if (!w->depth && w->len >= w->cap / 2) {
		utrace_pb_flush(w);
	}
}

/** A sink appending to a fixed region of memory */
struct utrace_pb_mem {
	uint8_t *data;
	size_t cap;
	size_t len;
};

static inline int
utrace_pb_mem_write(void *ctx, const uint8_t *buf, size_t len)
{
	struct utrace_pb_mem *mem = (struct utrace_pb_mem *)ctx;

	if (mem->cap - mem->len < len) {
		return UTRACE_PB_ENOSPC;
	}
	memcpy(mem->data + mem->len, buf, len);
	mem->len += len;
	return 0;
}

static inline struct utrace_pb_sink
utrace_pb_mem_sink(struct utrace_pb_mem *mem)
{
	struct utrace_pb_sink sink;

	sink.write = utrace_pb_mem_write;
	sink.ctx   = mem;
	return sink;
}

#ifdef UTRACE_PB_HAVE_FD_SINK
/** A sink writing to a file descriptor; ctx points at the int holding it */
static inline int
utrace_pb_fd_write(void *ctx, const uint8_t *buf, size_t len)
{
	int fd = *(const int *)ctx;

	while (len) {
		ssize_t ret = write(fd, buf, len);

		if (ret < 0 && errno == EINTR) {
			continue;
		}
		if (ret <= 0) {
			return ret < 0 && errno ? -errno : UTRACE_PB_EIO;
		}
		buf += ret;
		len -= (size_t)ret;
	}
	return 0;
}

static inline struct utrace_pb_sink
utrace_pb_fd_sink(int *fd)
{
	struct utrace_pb_sink sink;

	sink.write = utrace_pb_fd_write;
	sink.ctx   = fd;
	return sink;
}
#endif

#ifdef __cplusplus
}
#endif

#endif /* UTRACE_PB_H */

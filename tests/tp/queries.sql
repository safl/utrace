-- SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
--
-- SPDX-License-Identifier: BSD-3-Clause

-- What trace_processor makes of examples/gpu_queues.c's trace; tests/tp/expected.csv holds the
-- answers, one result set per statement. zig build tp compares the two.

SELECT p.pid, p.name AS process, t.tid, t.name AS thread
FROM thread t JOIN process p USING (upid)
WHERE p.pid = 4242
ORDER BY t.tid;

SELECT t.name, parent.name AS parent, p.pid
FROM track t
LEFT JOIN track parent ON t.parent_id = parent.id
LEFT JOIN process p ON p.upid = extract_arg(t.dimension_arg_set_id, 'upid')
WHERE t.name IN ('gpu0', 'queue0', 'queue1', 'inflight')
ORDER BY t.name;

SELECT s.ts, s.dur, s.name, s.category, COALESCE(th.name, tr.name) AS track, s.depth
FROM slice s
JOIN track tr ON s.track_id = tr.id
LEFT JOIN thread_track tt ON tt.id = s.track_id
LEFT JOIN thread th USING (utid)
ORDER BY s.ts, track;

SELECT s.ts, s.name, a.key, a.display_value
FROM slice s JOIN args a USING (arg_set_id)
WHERE a.key GLOB 'debug.*'
ORDER BY s.ts, a.key;

SELECT src.name AS src, src.ts AS src_ts, dst.name AS dst, dst.ts AS dst_ts, tr.name AS dst_track
FROM flow f
JOIN slice src ON f.slice_out = src.id
JOIN slice dst ON f.slice_in = dst.id
JOIN track tr ON dst.track_id = tr.id
ORDER BY src.ts;

SELECT t.name, c.ts, c.value
FROM counter c JOIN counter_track t ON c.track_id = t.id
ORDER BY c.ts, c.id;

SELECT name, idx, severity, value
FROM stats
WHERE value > 0 AND severity IN ('error', 'data_loss')
ORDER BY name, idx;

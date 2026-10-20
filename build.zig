// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause

const std = @import("std");

/// What include/utrace/perfetto/ holds writers for; each root's nested types come along
const perfetto_roots = [_][]const u8{
    "perfetto.protos.Trace",
    "perfetto.protos.TracePacket",
    "perfetto.protos.ClockSnapshot",
    "perfetto.protos.BuiltinClock",
    "perfetto.protos.TrackDescriptor",
    "perfetto.protos.ProcessDescriptor",
    "perfetto.protos.ThreadDescriptor",
    "perfetto.protos.CounterDescriptor",
    "perfetto.protos.TrackEvent",
    "perfetto.protos.DebugAnnotation",
};

const warnings = [_][]const u8{
    "-Wall",        "-Wextra",           "-Wpedantic", "-Werror",
    "-Wconversion", "-Wsign-conversion", "-Wshadow",
};

const Standard = struct { name: []const u8, lang: std.Build.Module.CSourceLanguage };

const standards = [_]Standard{
    .{ .name = "c99", .lang = .c },
    .{ .name = "c11", .lang = .c },
    .{ .name = "c17", .lang = .c },
    .{ .name = "c++11", .lang = .cpp },
    .{ .name = "c++17", .lang = .cpp },
    .{ .name = "c++20", .lang = .cpp },
};

/// examples/gpu_queues.c, held to the same warnings as the headers
fn example(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addIncludePath(b.path("include"));
    mod.addCSourceFile(.{ .file = b.path("examples/gpu_queues.c"), .flags = &(.{"-std=c99"} ++ warnings) });
    return b.addExecutable(.{ .name = "gpu_queues", .root_module = mod });
}

/// The trace the example writes when run
fn exampleTrace(b: *std.Build, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    const run = b.addRunArtifact(exe);
    return run.addOutputFileArg("gpu_queues.pftrace");
}

/// protoc's FileDescriptorSet of a .proto and everything it imports
fn descriptorSet(b: *std.Build, include_dir: []const u8, proto: []const u8, basename: []const u8) std.Build.LazyPath {
    const protoc = b.addSystemCommand(&.{ "protoc", "--include_imports" });
    protoc.addPrefixedDirectoryArg("-I", b.path(include_dir));
    const out = protoc.addPrefixedOutputFileArg("--descriptor_set_out=", basename);
    _ = protoc.addPrefixedDepFileOutputArg("--dependency_out=", b.fmt("{s}.d", .{basename}));
    protoc.addFileArg(b.path(b.fmt("{s}/{s}", .{ include_dir, proto })));
    return out;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pb = b.createModule(.{ .root_source_file = b.path("tools/pb.zig") });
    const gen = b.addExecutable(.{ .name = "gen", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/gen.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "pb", .module = pb }},
    }) });

    const perfetto = descriptorSet(b, "third-party/perfetto", "protos/perfetto/trace/trace.proto", "perfetto.pb");
    const gen_perfetto = b.addRunArtifact(gen);
    gen_perfetto.addFileArg(perfetto);
    gen_perfetto.addFileArg(b.path("third-party/perfetto/VERSION"));
    gen_perfetto.addArg(b.pathFromRoot("include/utrace/perfetto"));
    gen_perfetto.addArgs(&perfetto_roots);
    gen_perfetto.has_side_effects = true;
    b.step("gen", "Regenerate include/utrace/perfetto/ from the vendored protos").dependOn(&gen_perfetto.step);

    // the generator's own test input, written to the cache rather than to the tree
    const all_types = descriptorSet(b, "tests/gen", "all_types.proto", "all_types.pb");
    const gen_all_types = b.addRunArtifact(gen);
    gen_all_types.addFileArg(all_types);
    gen_all_types.addArg("-");
    const all_types_dir = gen_all_types.addOutputDirectoryArg("all_types");
    gen_all_types.addArgs(&.{ "utrace.test.AllTypes", "utrace.test.Top" });

    const descriptor = descriptorSet(b, "third-party/protobuf", "google/protobuf/descriptor.proto", "descriptor.pb");

    const test_step = b.step("test", "Compile every header in each C and C++ standard and run the tests");

    for (standards) |s| {
        const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        mod.addIncludePath(b.path("include"));
        mod.addIncludePath(all_types_dir);
        const flags = b.dupeStrings(&(.{b.fmt("-std={s}", .{s.name})} ++ warnings));
        mod.addCSourceFile(.{ .file = b.path("tests/compile.c"), .language = s.lang, .flags = flags });
        mod.addCSourceFile(.{ .file = b.path("tests/gen/compile.c"), .language = s.lang, .flags = flags });
        const obj = b.addObject(.{ .name = b.fmt("compile-{s}", .{s.name}), .root_module = mod });
        test_step.dependOn(&obj.step);
    }

    const gpu_queues = example(b, target, optimize);
    b.installArtifact(gpu_queues);
    const gpu_queues_trace = exampleTrace(b, gpu_queues);

    const c = b.addTranslateC(.{ .root_source_file = b.path("tests/c.h"), .target = target, .optimize = optimize });
    c.addIncludePath(b.path("include"));

    const gen_c = b.addTranslateC(.{ .root_source_file = b.path("tests/gen/c.h"), .target = target, .optimize = optimize });
    gen_c.addIncludePath(b.path("include"));
    gen_c.addIncludePath(all_types_dir);

    const zig_tests = [_]struct { file: []const u8, c: ?*std.Build.Step.TranslateC }{
        .{ .file = "tests/pb_test.zig", .c = c },
        .{ .file = "tests/trace_test.zig", .c = c },
        .{ .file = "tests/gen_test.zig", .c = gen_c },
        .{ .file = "tests/descriptor_test.zig", .c = null },
        .{ .file = "tests/example_test.zig", .c = null },
    };
    for (zig_tests) |t| {
        const mod = b.createModule(.{
            .root_source_file = b.path(t.file),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "pb", .module = pb }},
        });
        if (t.c) |tc| mod.addImport("c", tc.createModule());
        mod.addAnonymousImport("all_types.pb", .{ .root_source_file = all_types });
        mod.addAnonymousImport("descriptor.pb", .{ .root_source_file = descriptor });
        mod.addAnonymousImport("perfetto.pb", .{ .root_source_file = perfetto });
        mod.addAnonymousImport("gpu_queues.pftrace", .{ .root_source_file = gpu_queues_trace });
        const exe = b.addTest(.{ .name = std.fs.path.stem(t.file), .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(exe).step);
    }

    const tp_step = b.step("tp", "Check the example's trace with trace_processor (-Dtrace-processor=<trace_processor_shell>)");
    if (b.option([]const u8, "trace-processor", "Path to Perfetto's trace_processor_shell, for zig build tp")) |tp| {
        const query = b.addSystemCommand(&.{ tp, "query", "-f" });
        query.addFileArg(b.path("tests/tp/queries.sql"));
        query.addFileArg(gpu_queues_trace);
        const got = query.captureStdOut(.{});
        // progress and timings, which would read as failures in the build's output
        _ = query.captureStdErr(.{});
        const diff = b.addSystemCommand(&.{ "diff", "-u" });
        diff.addFileArg(b.path("tests/tp/expected.csv"));
        diff.addFileArg(got);
        tp_step.dependOn(&diff.step);
    } else {
        tp_step.dependOn(&b.addFail("zig build tp needs -Dtrace-processor=<path to trace_processor_shell>").step);
    }
}

// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause

const std = @import("std");

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
    const descriptor = descriptorSet(b, "third-party/protobuf", "google/protobuf/descriptor.proto", "descriptor.pb");

    const test_step = b.step("test", "Compile every header in each C and C++ standard and run the tests");

    for (standards) |s| {
        const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        mod.addIncludePath(b.path("include"));
        const flags = b.dupeStrings(&(.{b.fmt("-std={s}", .{s.name})} ++ warnings));
        mod.addCSourceFile(.{ .file = b.path("tests/compile.c"), .language = s.lang, .flags = flags });
        const obj = b.addObject(.{ .name = b.fmt("compile-{s}", .{s.name}), .root_module = mod });
        test_step.dependOn(&obj.step);
    }

    const c = b.addTranslateC(.{ .root_source_file = b.path("tests/c.h"), .target = target, .optimize = optimize });
    c.addIncludePath(b.path("include"));

    const zig_tests = [_]struct { file: []const u8, c: ?*std.Build.Step.TranslateC }{
        .{ .file = "tests/pb_test.zig", .c = c },
        .{ .file = "tests/descriptor_test.zig", .c = null },
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
        mod.addAnonymousImport("descriptor.pb", .{ .root_source_file = descriptor });
        const exe = b.addTest(.{ .name = std.fs.path.stem(t.file), .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(exe).step);
    }
}

// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause

const std = @import("std");

const warnings = [_][]const u8{
    "-Wall",        "-Wextra",           "-Wpedantic", "-Werror",
    "-Wconversion", "-Wsign-conversion", "-Wshadow",
};

const standards = [_]struct { name: []const u8, lang: std.Build.Module.CSourceLanguage }{
    .{ .name = "c99", .lang = .c },
    .{ .name = "c11", .lang = .c },
    .{ .name = "c17", .lang = .c },
    .{ .name = "c++11", .lang = .cpp },
    .{ .name = "c++17", .lang = .cpp },
    .{ .name = "c++20", .lang = .cpp },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Compile every header in each C and C++ standard and run the tests");

    for (standards) |s| {
        const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        mod.addIncludePath(b.path("include"));
        mod.addCSourceFile(.{
            .file = b.path("tests/compile.c"),
            .language = s.lang,
            .flags = b.dupeStrings(&(.{b.fmt("-std={s}", .{s.name})} ++ warnings)),
        });
        if (s.lang == .cpp) mod.link_libcpp = true;
        const obj = b.addObject(.{ .name = b.fmt("compile-{s}", .{s.name}), .root_module = mod });
        test_step.dependOn(&obj.step);
    }

    const c = b.addTranslateC(.{
        .root_source_file = b.path("tests/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(b.path("include"));

    const pb_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/pb_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c.createModule() }},
    }) });
    test_step.dependOn(&b.addRunArtifact(pb_tests).step);
}

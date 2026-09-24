const std = @import("std");

const zlib_sources = [_][]const u8{
    "adler32.c",
    "compress.c",
    "crc32.c",
    "deflate.c",
    "infback.c",
    "inffast.c",
    "inflate.c",
    "inftrees.c",
    "trees.c",
    "uncompr.c",
    "zutil.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `ZLIB_CONST` makes `next_in` a pointer to const, so input slices can be
    // handed to zlib without casting their constness away.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/zlib/zlib.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path("vendor/zlib"));
    translate_c.defineCMacro("ZLIB_CONST", null);

    const mod = b.addModule("zlib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("c", translate_c.createModule());
    mod.addIncludePath(b.path("vendor/zlib"));
    mod.addCSourceFiles(.{
        .root = b.path("vendor/zlib"),
        .files = &zlib_sources,
        .flags = &.{ "-std=c99", "-DZLIB_CONST" },
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

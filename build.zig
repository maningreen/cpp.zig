const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const main = b.addModule("root", .{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .root_module = main,
        .name = "translator",
    });

    const xmlDep = b.dependency("xml", .{ .target = target, .optimize = optimize });
    const xml = xmlDep.module("xml");
    main.addImport("xml", xml);

    _ = b.installArtifact(exe);

    const runStep = b.step("run", "Runs the artifact");
    const runExe = b.addRunArtifact(exe);
    runStep.dependOn(&runExe.step);

    if (b.args) |args| {
        runExe.addArgs(args);
    }

    const runTest = b.step("test", "runs tests");
    runTest.dependOn(&exe.step);

    const runTestMod = b.createModule(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("test/main.zig"),
        .link_libcpp = true,
    });
    runTestMod.addCSourceFiles(.{
        .files = &.{"test.cpp"},
        .flags = &.{
            "-fno-inline",
        },
        .language = .cpp,
        .root = b.path("test"),
    });

    const runTool = b.addRunArtifact(exe);

    runTool.addFileArg(b.path("test/test.hpp"));

    runTestMod.addImport("testing", b.createModule(.{
        .link_libcpp = true,
        .optimize = optimize,
        .target = target,
        .root_source_file = runTool.captureStdOut(.{.basename = "testing.zig"}),
    }));

    const testExe = b.addExecutable(.{
        .name = "test",
        .root_module = runTestMod,
        .use_llvm = true,
    });
    testExe.step.dependOn(&runTool.step);
    runTest.dependOn(&b.addRunArtifact(testExe).step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const main_mod = b.addModule("rss", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("main.zig"),
    });
    const main_ref_mod = b.addModule("rss", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("main_ref.zig"),
    });

    const zig_xml = b.dependency("zigxml", .{ .target = target, .optimize = optimize });
    main_mod.addImport("xml", zig_xml.module("xml"));
    main_ref_mod.addImport("xml", zig_xml.module("xml"));
    const main = b.addExecutable(.{
        .name = "main",
        .root_module = main_mod
    });
    b.installArtifact(main);

    const main_ref = b.addExecutable(.{
        .name = "main_ref",
        .root_module = main_ref_mod
    });
    b.installArtifact(main_ref);

    const tests = b.addTest(.{
       .root_module = main_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "run tests");
    test_step.dependOn(&run_tests.step);

}

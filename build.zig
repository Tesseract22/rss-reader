const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const rss_reader_mod = b.addModule("rss", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("src/rss_reader.zig"),
    });

    const gui_ref_mod = b.addModule("gui_ref", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("src/gui_ref.zig"),

    });

    const zig_xml = b.dependency("zigxml", .{ .target = target, .optimize = optimize });
    const zig_sqlite = b.dependency("zigsqlite", .{ .target = target, .optimize = optimize });
    const zig2d = b.dependency("zig2d", .{ .target = target, .optimize = optimize });

    rss_reader_mod.addImport("xml", zig_xml.module("xml"));
    rss_reader_mod.addImport("sqlite", zig_sqlite.module("sqlite"));
    rss_reader_mod.addImport("gl", zig2d.module("gl"));
    rss_reader_mod.addCSourceFile(.{
        .file = b.path("thirdparty/strptime/LibOb_strptime.c"),
    });
    rss_reader_mod.addIncludePath(b.path("."));
    rss_reader_mod.linkSystemLibrary("imm32", .{ });

    gui_ref_mod.addImport("gl", zig2d.module("gl"));
    gui_ref_mod.linkSystemLibrary("imm32", .{ });

    
    //
    // Create & Install exes'
    //
    const rss_reader = b.addExecutable(.{
        .name = "rss_reader",
        .root_module = rss_reader_mod,
    });
    
    const install_rss_reader = b.addInstallArtifact(rss_reader, .{});
    const rss_reader_step = b.step("rss-reader", "");
    rss_reader_step.dependOn(&install_rss_reader.step);
    b.installArtifact(rss_reader);


    const gui_ref = b.addExecutable(.{
        .name = "gui_ref",
        .root_module = gui_ref_mod
    });
    b.installArtifact(gui_ref);
}

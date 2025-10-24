const std = @import("std");


pub fn add_ui(b: *std.Build, mod: *std.Build.Module, is_windows: bool) void {
    mod.addCSourceFile(.{
        .flags = &.{ "-DRGFW_IMPLEMENTATION", "-DRGFW_OPENGL", "-DRGFW_ADVANCED_SMOOTH_RESIZE" },
        .language = .c,
        .file = b.path("thirdparty/RGFW/RGFW.h"),
    });
    mod.addCSourceFile(.{
        .flags = &.{ "-DGLAD_GL_IMPLEMENTATION", "-DGLAD_MALLOC=malloc", "-DGLAD_FREE=free" },
        .language = .c,
        .file = b.path("thirdparty/glad.h"),
    });
    if (is_windows) {
        mod.linkSystemLibrary("gdi32", .{});
        mod.linkSystemLibrary("opengl32", .{});
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const main_mod = b.addModule("rss", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("src/main.zig"),
    });
    main_mod.addCSourceFile(.{
        .file = b.path("thirdparty/strptime/LibOb_strptime.c"),
    });
    main_mod.addCSourceFile(.{
        .flags = &.{ "-DRGFW_IMPLEMENTATION", "-DRGFW_OPENGL" },
        .language = .c,
        .file = b.path("thirdparty/RGFW/RGFW.h"),
    });
    if (target.result.os.tag == .windows)
        main_mod.linkSystemLibrary("gdi32", .{});

    main_mod.sanitize_c = .full;
    main_mod.addIncludePath(b.path("."));

    const gui_ref_mod = b.addModule("gui_ref", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("src/gui_ref.zig"),

    });
    gui_ref_mod.addIncludePath(b.path("."));
    add_ui(b, gui_ref_mod, target.result.os.tag == .windows);

    const gui_mod = b.addModule("gui", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("src/gui.zig"),

    });

    gui_mod.addIncludePath(b.path("."));
    add_ui(b, gui_mod, target.result.os.tag == .windows);


    const xml_ref_mod = b.addModule("rss", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/xml_ref.zig"),
    });

    const zig_xml = b.dependency("zigxml", .{ .target = target, .optimize = optimize });
    const zig_sqlite = b.dependency("zigsqlite", .{ .target = target, .optimize = optimize });
    main_mod.addImport("xml", zig_xml.module("xml"));
    main_mod.addImport("sqlite", zig_sqlite.module("sqlite"));
    xml_ref_mod.addImport("xml", zig_xml.module("xml"));
    const main = b.addExecutable(.{
        .name = "main",
        .root_module = main_mod,
    });

    //
    // Create & Install exes'
    //
    b.installArtifact(main);

    const gui_ref = b.addExecutable(.{
        .name = "gui_ref",
        .root_module = gui_ref_mod
    });
    b.installArtifact(gui_ref);

    const gui = b.addExecutable(.{
        .name = "gui",
        .root_module = gui_mod
    });
    b.installArtifact(gui);

    const xml_ref = b.addExecutable(.{
        .name = "xml_ref",
        .root_module = xml_ref_mod
    });
    b.installArtifact(xml_ref);

    const tests = b.addTest(.{
       .root_module = main_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "run tests");
    test_step.dependOn(&run_tests.step);

}

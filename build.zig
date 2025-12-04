const std = @import("std");

const cimgui = @import("cimgui_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // glfw
    const dep_glfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });

    // zlm
    const dep_zlm = b.dependency("zlm", .{});

    // opencl
    const mod_cl = b.createModule(.{
        .root_source_file = b.path("src/cl.zig"),
        .target = target,
        .optimize = optimize,
    });

    // my noize
    const dep_noize = b.dependency("noize", .{
        .target = target,
        .optimize = optimize,
        .use_cl = true,
    });

    const mod_noize = dep_noize.module("noize");
    mod_noize.addImport("cl", mod_cl);

    const exe = b.addExecutable(.{
        .name = "isolated",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glfw", .module = dep_glfw.module("glfw") },
                .{ .name = "zlm", .module = dep_zlm.module("zlm") },
                .{ .name = "noize", .module = mod_noize },
                .{ .name = "cl", .module = mod_cl },
            },
        }),
    });

    // imgui
    const dep_cimgui = b.dependency("cimgui_zig", .{
        .target = target,
        .optimize = optimize,
        .platform = cimgui.Platform.GLFW,
        .renderer = cimgui.Renderer.OpenGL3,
    });

    const lib_cimgui = dep_cimgui.artifact("cimgui");

    exe.linkLibrary(lib_cimgui);

    exe.linkLibC();
    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("GL");
    exe.linkSystemLibrary("OpenCL");
    exe.linkSystemLibrary("EGL");
    exe.linkSystemLibrary("dl");
    exe.root_module.addCSourceFile(.{.file = b.path("./src/glad/src/glad.c")});
    exe.addIncludePath(b.path("./src/glad/include"));

    b.installArtifact(exe);
}

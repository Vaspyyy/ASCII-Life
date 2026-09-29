const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip executable symbols (default for release)") orelse (optimize != .Debug);
    const protocol = b.option([]const u8, "xdg-shell", "Path to stable xdg-shell.xml") orelse "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml";
    const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", protocol });
    const h = header.addOutputFileArg("xdg-shell-client-protocol.h");
    const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", protocol });
    const c = code.addOutputFileArg("xdg-shell-protocol.c");
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .strip = strip });
    mod.addIncludePath(b.path("src"));
    mod.addIncludePath(h.dirname());
    mod.addCSourceFile(.{ .file = c, .flags = &.{"-Os"} });
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("xkbcommon", .{});
    mod.linkSystemLibrary("vulkan", .{});
    inline for (.{ "vert", "frag" }) |stage| {
        const shader = b.addSystemCommand(&.{ "glslc", "-Os", "--target-env=vulkan1.0" });
        shader.addFileArg(b.path("shaders/cell." ++ stage));
        shader.addArg("-o");
        const spv = shader.addOutputFileArg("cell." ++ stage ++ ".spv");
        mod.addAnonymousImport("cell." ++ stage ++ ".spv", .{ .root_source_file = spv });
    }
    const exe = b.addExecutable(.{ .name = "ascii-life", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Explore the native glyph landscape").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize }) });
    b.step("test", "Check deterministic terrain, camera and glyph rendering").dependOn(&b.addRunArtifact(tests).step);
}

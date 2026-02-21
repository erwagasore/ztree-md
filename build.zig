const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ztree_dep = b.dependency("ztree", .{
        .target = target,
        .optimize = optimize,
    });

    // Library module
    const lib_mod = b.addModule("ztree-md", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztree", .module = ztree_dep.module("ztree") },
        },
    });

    // Library artifact (for linking)
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "ztree-md",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztree", .module = ztree_dep.module("ztree") },
        },
    });

    const t = b.addTest(.{
        .root_module = test_mod,
    });
    const run_t = b.addRunArtifact(t);
    test_step.dependOn(&run_t.step);
}

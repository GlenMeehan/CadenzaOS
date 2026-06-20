const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Define module "proj" with src/ as its root
    const proj_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel/kernel.zig"),
                                    .target = target,
                                    .optimize = optimize,
    });

    // Define mkfs module
    const mkfs_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/mkfs.zig"),
                                    .imports = &.{ .{ .name = "proj", .module = proj_mod } },
                                    .target = target,
                                    .optimize = optimize,
    });

    // Create mkfs executable
    const mkfs = b.addExecutable(.{
        .name = "mkfs",
        .root_module = mkfs_mod,
    });

    b.installArtifact(mkfs);
}

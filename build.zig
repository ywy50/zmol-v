const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("smolv", .{
        .root_source_file = b.path("src/smolv.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A shared library with a C ABI, for callers that are not Zig.
    const lib = b.addLibrary(.{
        .name = "zmolv",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);

    const unity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unity.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/smolv.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const c_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(unity_tests).step);
    test_step.dependOn(&b.addRunArtifact(c_api_tests).step);
}

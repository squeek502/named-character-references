const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("named_character_references", .{
        .root_source_file = b.path("src/named_character_references.zig"),
        .target = target,
        .optimize = optimize,
    });

    {
        const mod_tests = b.addTest(.{
            .root_module = mod,
        });
        const run_mod_tests = b.addRunArtifact(mod_tests);

        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "named_character_references", .module = mod }},
            }),
        });
        const run_tests = b.addRunArtifact(tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
        test_step.dependOn(&run_tests.step);
    }

    {
        const bench_exe = b.addExecutable(.{
            .name = "bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/bench.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "named_character_references", .module = mod }},
            }),
        });
        const install_bench = b.addInstallArtifact(bench_exe, .{});

        const bench_step = b.step("bench", "Build and install benchmark");
        bench_step.dependOn(&install_bench.step);
    }

    {
        const generate_exe = b.addExecutable(.{
            .name = "generate",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/generate.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "named_character_references", .module = mod }},
            }),
        });
        const install_generate = b.addInstallArtifact(generate_exe, .{});

        const generate_step = b.step("generate", "Build and install generate tool");
        generate_step.dependOn(&install_generate.step);
    }
}

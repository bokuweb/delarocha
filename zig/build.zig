const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "delarocha_zig",
        .root_module = module,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = module,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_tests.step);

    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_exe = b.addExecutable(.{
        .name = "delarocha_bench",
        .root_module = bench_module,
    });
    const run_bench = b.addRunArtifact(bench_exe);

    const bench_step = b.step("bench", "Run tokenizer microbenchmark");
    bench_step.dependOn(&run_bench.step);
}

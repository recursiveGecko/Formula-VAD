const std = @import("std");

const KV = struct {
    @"0": []const u8,
    @"1": []const u8,

    pub fn k(self: @This()) []const u8 {
        return self.@"0";
    }

    pub fn v(self: @This()) []const u8 {
        return self.@"1";
    }
};

const CommonOptions = struct {
    target: std.zig.CrossTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn linkPackage(
    b: *std.Build,
    exe: *std.Build.CompileStep,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
) !void {
    const common_options = CommonOptions{
        .target = target,
        .optimize = optimize,
    };

    const pkg = b.createModule(.{
        .source_file = .{ .path = thisFileDir() ++ "/src/package.zig" },
        .dependencies = &.{},
    });

    exe.addModule("formula_vad", pkg);
    try addRnnoise(b, exe, common_options);
    try addKissFFT(b, exe, common_options);
    try addSndfile(b, exe, common_options);
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common_options = CommonOptions{
        .target = target,
        .optimize = optimize,
    };

    //
    // Main formula-vad exe
    //

    const exe = b.addExecutable(.{
        .name = "formula-vad",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    // try addZigGameDev(b, exe, common_options);
    try addClap(b, exe, common_options);
    try addSndfile(b, exe, common_options);
    try addKissFFT(b, exe, common_options);
    try addRnnoise(b, exe, common_options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    //
    // formula-vad tests
    //

    const unit_tests = b.addTest(.{
        .name = "formula-vad-test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    // try addZigGameDev(b, unit_tests, common_options);
    try addKissFFT(b, unit_tests, common_options);
    try addRnnoise(b, unit_tests, common_options);

    b.installArtifact(unit_tests);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    //
    // vad-evaluator executable (evaluates given input against a reference file)
    //
    const evaluator_exe = b.addExecutable(.{
        .name = "vad-evaluator",
        .root_source_file = .{ .path = "src/Evaluator.zig" },
        .target = target,
        .optimize = optimize,
    });
    try addClap(b, evaluator_exe, common_options);
    b.installArtifact(evaluator_exe);

    const evaluator_run_cmd = b.addRunArtifact(evaluator_exe);
    evaluator_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        evaluator_run_cmd.addArgs(args);
    }
    const evaluator_run_step = b.step("evaluator", "Run the evaluator (VAD output + reference output)");
    evaluator_run_step.dependOn(&evaluator_run_cmd.step);

    //
    // vad-simulator executable  - Runs VAD against given audio file and evaluates the results against a reference file
    //
    const simulator_exe = b.addExecutable(.{
        .name = "simulator",
        .root_source_file = .{ .path = "src/simulator.zig" },
        .target = target,
        .optimize = optimize,
    });
    try addClap(b, simulator_exe, common_options);
    try addSndfile(b, simulator_exe, common_options);
    try addKissFFT(b, simulator_exe, common_options);
    try addRnnoise(b, simulator_exe, common_options);
    b.installArtifact(simulator_exe);

    const simulator_run_cmd = b.addRunArtifact(simulator_exe);
    simulator_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        simulator_run_cmd.addArgs(args);
    }
    const simulator_run_step = b.step("simulator", "Run the simulator (audio file + reference output)");
    simulator_run_step.dependOn(&simulator_run_cmd.step);
}

var kiss_fft_lib: ?*std.Build.Step.Compile = null;
fn addKissFFT(b: *std.Build, exe: *std.Build.Step.Compile, options: CommonOptions) !void {
    const macros: []const KV = &.{
        .{ "kiss_fft_scalar", "float" },
    };

    if (kiss_fft_lib == null) {
        const dir = thisFileDir() ++ "/lib/kissfft";
        const source_files = try prefixedPaths(b.allocator, dir, &.{
            // "kfc.c",
            "kiss_fft.c",
            // "kiss_fftnd.c",
            // "kiss_fftndr.c",
            "kiss_fftr.c",
        });

        const lib = b.addStaticLibrary(.{
            .name = "kissfft",
            .optimize = options.optimize,
            .target = options.target,
        });

        lib.linkLibC();
        lib.addCSourceFiles(source_files, &.{"-Wall"});

        for (macros) |macro| {
            lib.defineCMacro(macro.k(), macro.v());
        }

        kiss_fft_lib = lib;
    }

    exe.addIncludePath(thisFileDir() ++ "/lib/kissfft");
    exe.linkLibrary(kiss_fft_lib.?);
}

var rnnoiseLib: ?*std.Build.Step.Compile = null;
fn addRnnoise(b: *std.Build, exe: *std.Build.Step.Compile, options: CommonOptions) !void {
    if (rnnoiseLib == null) {
        const dir = thisFileDir() ++ "/lib/rnnoise/src";
        const rnnSources = try prefixedPaths(b.allocator, dir, &.{
            "denoise.c",
            "celt_lpc.c",
            "kiss_fft.c",
            "pitch.c",
            "rnn_data.c",
            "rnn_reader.c",
            "rnn.c",
        });

        var lib = b.addStaticLibrary(.{
            .name = "rnnoise",
            .target = options.target,
            .optimize = options.optimize,
        });
        lib.addCSourceFiles(rnnSources, &.{});
        lib.linkLibC();
        lib.addIncludePath(thisFileDir() ++ "/lib/rnnoise/include");

        rnnoiseLib = lib;
    }

    exe.linkLibrary(rnnoiseLib.?);
    exe.addIncludePath(thisFileDir() ++ "/lib/rnnoise/include");
}

fn addSndfile(b: *std.Build, exe: *std.Build.Step.Compile, options: CommonOptions) !void {
    _ = options;
    _ = b;
    exe.linkSystemLibrary("sndfile");
}

var clap_module: ?*std.Build.Module = null;
fn addClap(b: *std.Build, exe: *std.Build.Step.Compile, options: CommonOptions) !void {
    _ = options;
    if (clap_module == null) {
        clap_module = b.createModule(.{
            .source_file = .{ .path = "lib/zig-clap/clap.zig" },
        });
    }

    exe.addModule("clap", clap_module.?);
}

fn prefixedPaths(allocator: std.mem.Allocator, prefix: []const u8, paths: []const []const u8) ![][]const u8 {
    const prefixed_paths = try allocator.alloc([]const u8, paths.len);

    for (paths, 0..) |path, i| {
        prefixed_paths[i] = try std.fs.path.joinZ(allocator, &.{ prefix, path });
    }

    return prefixed_paths;
}

inline fn thisFileDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}

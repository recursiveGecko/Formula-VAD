const std = @import("std");
const Build = std.Build;

const CommonOptions = struct {
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    clap_dep: *Build.Dependency,
    onnx_dep: *Build.Dependency,
    kissfft_dep: *Build.Dependency,
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const onnx_dep = b.dependency("zig_onnxruntime", .{
        .target = target,
        .optimize = optimize,
    });

    const kissfft_dep = b.dependency("kissfft", .{
        .target = target,
        .optimize = optimize,
    });
    const common_options = CommonOptions{
        .target = target,
        .optimize = optimize,
        .clap_dep = clap_dep,
        .onnx_dep = onnx_dep,
        .kissfft_dep = kissfft_dep,
    };

    //
    // onnxruntime shared library
    //
    // ugly hack to install onnxruntime.so libraries (without symlinks: https://github.com/ziglang/zig/pull/18619)
    // this works in this case because SONAME of libonnxruntime.so is directly referencing minor version `libonnxruntime.so.x.y.z`, which doesn't require symlinks
    // inspired by https://medium.com/@edlyuu/zig-package-manager-2-wtf-is-build-zig-zon-and-build-zig-0-11-0-update-5bc46e830fc1
    //
    const install_onnx_libs = b.addInstallDirectory(.{
        .source_dir = onnx_dep.module("onnxruntime_lib").root_source_file.?,
        .install_dir = .bin,
        .install_subdir = "lib",
    });

    //
    // Main formula-vad exe
    //

    const main_exe = b.addExecutable(.{
        .name = "formula-vad",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    try addClap(b, main_exe, common_options);
    try addSndfile(b, main_exe, common_options);
    try addKissFFT(b, main_exe, common_options);
    try addOnnx(b, main_exe, common_options);
    try setRPath(main_exe);

    const main_exe_install = b.addInstallArtifact(main_exe, .{});
    main_exe_install.step.dependOn(&install_onnx_libs.step);
    b.getInstallStep().dependOn(&main_exe_install.step);

    const main_run_artifact = b.addRunArtifact(main_exe);
    main_run_artifact.step.dependOn(&main_exe_install.step);

    if (b.args) |args| {
        main_run_artifact.addArgs(args);
    }
    const main_run_step = b.step("run", "Run the main program");
    main_run_step.dependOn(&main_run_artifact.step);

    //
    // formula-vad tests
    //

    const test_exe = b.addTest(.{
        .name = "formula-vad-test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    try addClap(b, test_exe, common_options);
    try addSndfile(b, test_exe, common_options);
    try addKissFFT(b, test_exe, common_options);
    try addOnnx(b, test_exe, common_options);

    const test_run_artifact = b.addRunArtifact(test_exe);
    const test_run_step = b.step("test", "Run unit tests");
    test_run_step.dependOn(&test_run_artifact.step);

    //
    // evaluator executable (evaluates given input against a reference file)
    //
    const eval_exe = b.addExecutable(.{
        .name = "evaluator",
        .root_source_file = .{ .path = "src/Evaluator.zig" },
        .target = target,
        .optimize = optimize,
    });
    try addClap(b, eval_exe, common_options);
    try setRPath(eval_exe);

    const eval_exe_install = b.addInstallArtifact(eval_exe, .{});
    b.getInstallStep().dependOn(&eval_exe_install.step);

    const eval_run_artifact = b.addRunArtifact(eval_exe);
    eval_run_artifact.step.dependOn(&eval_exe_install.step);
    if (b.args) |args| {
        eval_run_artifact.addArgs(args);
    }
    const eval_run_step = b.step("evaluator", "Run the evaluator (VAD output + reference output)");
    eval_run_step.dependOn(&eval_run_artifact.step);

    //
    // vad-simulator executable  - Runs VAD against given audio file and evaluates the results against a reference file
    //
    const sim_exe = b.addExecutable(.{
        .name = "simulator",
        .root_source_file = .{ .path = "src/simulator.zig" },
        .target = target,
        .optimize = optimize,
    });
    try addClap(b, sim_exe, common_options);
    try addSndfile(b, sim_exe, common_options);
    try addKissFFT(b, sim_exe, common_options);
    try addOnnx(b, sim_exe, common_options);
    try setRPath(sim_exe);

    const sim_exe_install = b.addInstallArtifact(sim_exe, .{});
    sim_exe_install.step.dependOn(&install_onnx_libs.step);
    b.getInstallStep().dependOn(&sim_exe_install.step);

    const sim_run_artifact = b.addRunArtifact(sim_exe);
    sim_run_artifact.step.dependOn(&sim_exe_install.step);
    if (b.args) |args| {
        sim_run_artifact.addArgs(args);
    }
    const sim_run_step = b.step("simulator", "Run the simulator (audio file + reference output)");
    sim_run_step.dependOn(&sim_run_artifact.step);
}

fn setRPath(exe: *Build.Step.Compile) !void {
    exe.root_module.addRPathSpecial("$ORIGIN/lib");
    exe.each_lib_rpath = false;
}

var kiss_fft_lib: ?*Build.Step.Compile = null;
fn addKissFFT(b: *Build, exe: *Build.Step.Compile, options: CommonOptions) !void {
    const Pair = [2][]const u8;
    const macros: []const Pair = &.{
        .{ "kiss_fft_scalar", "float" },
    };

    if (kiss_fft_lib == null) {
        const source_files = &.{
            // "kfc.c",
            "kiss_fft.c",
            // "kiss_fftnd.c",
            // "kiss_fftndr.c",
            "kiss_fftr.c",
        };

        const lib = b.addStaticLibrary(.{
            .name = "kissfft",
            .optimize = options.optimize,
            .target = options.target,
        });

        lib.linkLibC();
        lib.addCSourceFiles(.{
            .root = options.kissfft_dep.path("."),
            .files = source_files,
            .flags = &.{"-Wall"},
        });

        for (macros) |macro| {
            lib.defineCMacro(macro[0], macro[1]);
        }

        kiss_fft_lib = lib;
    }

    exe.addIncludePath(options.kissfft_dep.path("."));
    exe.linkLibrary(kiss_fft_lib.?);
}

fn addSndfile(b: *Build, exe: *Build.Step.Compile, options: CommonOptions) !void {
    _ = options;
    _ = b;
    exe.linkSystemLibrary("sndfile");
}

fn addClap(b: *Build, exe: *Build.Step.Compile, options: CommonOptions) !void {
    _ = b;
    exe.root_module.addImport("clap", options.clap_dep.module("clap"));
}

fn addOnnx(b: *Build, exe: *Build.Step.Compile, options: CommonOptions) !void {
    _ = b;
    exe.root_module.addImport("onnxruntime", options.onnx_dep.module("zig-onnxruntime"));
}

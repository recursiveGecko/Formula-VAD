const std = @import("std");
const Build = std.Build;

const CommonOptions = struct {
    build: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common_options = CommonOptions{
        .build = b,
        .target = target,
        .optimize = optimize,
    };

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
    const main_exe_install = b.addInstallArtifact(main_exe, .{});
    b.getInstallStep().dependOn(&main_exe_install.step);

    try addClap(main_exe, common_options);
    try addSndfile(main_exe, common_options);
    try addKissFFT(main_exe, common_options);
    try addOnnx(main_exe, main_exe_install, common_options);
    try addDeepFilterNet(main_exe, main_exe_install, common_options);
    try addDuckDb(main_exe, main_exe_install, common_options);

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
    try addClap(test_exe, common_options);
    try addSndfile(test_exe, common_options);
    try addDeepFilterNet(test_exe, null, common_options);
    try addKissFFT(test_exe, common_options);
    try addOnnx(test_exe, null, common_options);

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
    try addClap(eval_exe, common_options);

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
    const sim_exe_install = b.addInstallArtifact(sim_exe, .{});
    b.getInstallStep().dependOn(&sim_exe_install.step);

    try addClap(sim_exe, common_options);
    try addSndfile(sim_exe, common_options);
    try addKissFFT(sim_exe, common_options);
    try addOnnx(sim_exe, sim_exe_install, common_options);
    try addDeepFilterNet(sim_exe, sim_exe_install, common_options);

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

fn addSndfile(exe: *Build.Step.Compile, options: CommonOptions) !void {
    _ = options;
    exe.linkSystemLibrary("sndfile");
}

fn addClap(exe: *Build.Step.Compile, options: CommonOptions) !void {
    const clap_dep = options.build.dependency("clap", .{
        .target = options.target,
        .optimize = options.optimize,
    });

    exe.root_module.addImport("clap", clap_dep.module("clap"));
}

var kiss_fft_lib: ?*Build.Step.Compile = null;
fn addKissFFT(exe: *Build.Step.Compile, options: CommonOptions) !void {
    const kissfft_dep = options.build.dependency("kissfft", .{
        .target = options.target,
        .optimize = options.optimize,
    });

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

        const lib = options.build.addStaticLibrary(.{
            .name = "kissfft",
            .optimize = options.optimize,
            .target = options.target,
        });

        lib.linkLibC();
        lib.addCSourceFiles(.{
            .root = kissfft_dep.path("."),
            .files = source_files,
            .flags = &.{"-Wall"},
        });

        for (macros) |macro| {
            lib.defineCMacro(macro[0], macro[1]);
        }

        kiss_fft_lib = lib;
    }

    exe.addIncludePath(kissfft_dep.path("."));
    exe.linkLibrary(kiss_fft_lib.?);
}

fn addDeepFilterNet(exe: *Build.Step.Compile, exe_install: ?*Build.Step.InstallArtifact, options: CommonOptions) !void {
    const b = options.build;
    const libdf_root = try std.fs.path.join(b.allocator, &.{ b.pathFromRoot("tmp"), "libdf" });
    const include_path = try std.fs.path.join(b.allocator, &.{ libdf_root, "include" });
    const lib_path = try std.fs.path.join(b.allocator, &.{ libdf_root, "lib" });

    exe.addIncludePath(.{ .path = include_path });

    // Linking unwind or libcpp breaks stack traces
    // exe.addObjectFile(.{ .path = "tmp/libdf/lib/libdeepfilter.a" });
    // exe.linkLibCpp(); // either works
    // exe.linkSystemLibrary("unwind");

    exe.linkSystemLibrary("deepfilter");
    exe.addLibraryPath(.{ .path = lib_path });
    exe.linkLibC();
    try setRPath(exe);

    // Copy libs to output directory
    if (exe_install) |install| {
        const dst_path = try std.fs.path.join(b.allocator, &.{ b.install_path, "bin", "lib" });
        const install_dfn_libs = copySharedObjectsWithSymlinks(b, lib_path, dst_path);
        install.step.dependOn(&install_dfn_libs.step);
    }
}

fn addOnnx(exe: *Build.Step.Compile, exe_install: ?*Build.Step.InstallArtifact, options: CommonOptions) !void {
    const b = options.build;
    const onnx_dep = b.dependency("zig_onnxruntime", .{
        .target = options.target,
        .optimize = options.optimize,
    });

    exe.root_module.addImport("onnxruntime", onnx_dep.module("zig-onnxruntime"));
    try setRPath(exe);

    //
    // onnxruntime shared library
    //
    // ugly hack to install onnxruntime.so libraries (without symlinks: https://github.com/ziglang/zig/pull/18619)
    // this works in this case because SONAME of libonnxruntime.so is directly referencing minor version `libonnxruntime.so.x.y.z`, which doesn't require symlinks
    // inspired by https://medium.com/@edlyuu/zig-package-manager-2-wtf-is-build-zig-zon-and-build-zig-0-11-0-update-5bc46e830fc1
    //
    if (exe_install) |install| {
        const src_path = onnx_dep.module("onnxruntime_lib").root_source_file.?.getPath(b);
        const dst_path = try std.fs.path.join(b.allocator, &.{ b.install_path, "bin", "lib" });

        // const install_onnx_libs = options.build.addInstallDirectory(.{
        //     .source_dir = .{ .path = src_path },
        //     .install_dir = .bin,
        //     .install_subdir = "lib",
        // });
        // install.step.dependOn(&install_onnx_libs.step);

        const install_onnx_symlinks = copySharedObjectsWithSymlinks(b, src_path, dst_path);
        install.step.dependOn(&install_onnx_symlinks.step);
    }
}

var download_duckdb: ?*Build.Step.Run = null;
fn addDuckDb(exe: *Build.Step.Compile, exe_install: ?*Build.Step.InstallArtifact, options: CommonOptions) !void {
    const b = options.build;
    const duckdb_release = "v0.10.1";
    const platform_dir = "linux-amd64";

    const lib_root = try std.fs.path.join(b.allocator, &.{ b.pathFromRoot("lib"), "libduckdb", platform_dir });
    const dynlib_name = "libduckdb.so";
    const dynlib_src_path = try std.fs.path.join(b.allocator, &.{ lib_root, dynlib_name });

    // This step download libduckdb in `lib/` directory
    if (download_duckdb == null) {
        const cmd = b.addSystemCommand(&.{
            "bash",
            b.pathFromRoot("lib/libduckdb/update.sh"),
            duckdb_release,
        });
        _ = cmd.captureStdOut();
        cmd.expectExitCode(0);

        download_duckdb = cmd;
    }
    exe.step.dependOn(&download_duckdb.?.step);

    const zuckdb = b.dependency("zuckdb", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("zuckdb");

    zuckdb.addIncludePath(.{ .path = b.pathFromRoot("lib/libduckdb") });
    exe.root_module.addImport("zuckdb", zuckdb);
    try setRPath(exe);

    // Copy libs to output directory
    if (exe_install) |install| {
        const dst_rel_path = try std.fs.path.join(b.allocator, &.{ "lib", dynlib_name });
        const install_shared_lib = b.addInstallBinFile(.{ .path = dynlib_src_path }, dst_rel_path);
        install.step.dependOn(&install_shared_lib.step);
    }
}

fn copySharedObjectsWithSymlinks(b: *Build, src_path: []const u8, dst_path: []const u8) *Build.Step.Run {
    const cmd = b.addSystemCommand(&.{ "find", src_path, "-maxdepth", "1", "-iname", "*.so*", "-exec", "cp", "-d", "{}", dst_path, ";" });

    cmd.expectExitCode(0);
    return cmd;
}

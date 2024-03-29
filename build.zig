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
    try addClap(main_exe, common_options);
    try addSndfile(main_exe, common_options);
    try addKissFFT(main_exe, common_options);
    try addOnnx(main_exe, common_options);
    try addDeepFilterNet(main_exe, common_options);
    try addDuckDb(main_exe, common_options);

    const main_exe_install = b.addInstallArtifact(main_exe, .{});
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
    try addClap(test_exe, common_options);
    try addSndfile(test_exe, common_options);
    try addDeepFilterNet(test_exe, common_options);
    try addKissFFT(test_exe, common_options);
    try addOnnx(test_exe, common_options);
    try addDuckDb(test_exe, common_options);
    // Tests won't be installed, we can't rely on relative RPATH
    test_exe.each_lib_rpath = true;

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
    // simulator executable  - Runs VAD against given audio file and evaluates the results against a reference file
    //
    const sim_exe = b.addExecutable(.{
        .name = "simulator",
        .root_source_file = .{ .path = "src/simulator.zig" },
        .target = target,
        .optimize = optimize,
    });
    try addClap(sim_exe, common_options);
    try addSndfile(sim_exe, common_options);
    try addKissFFT(sim_exe, common_options);
    try addOnnx(sim_exe, common_options);
    try addDeepFilterNet(sim_exe, common_options);
    try addDuckDb(sim_exe, common_options);

    const sim_exe_install = b.addInstallArtifact(sim_exe, .{});
    b.getInstallStep().dependOn(&sim_exe_install.step);

    const sim_run_artifact = b.addRunArtifact(sim_exe);
    sim_run_artifact.step.dependOn(&sim_exe_install.step);
    if (b.args) |args| {
        sim_run_artifact.addArgs(args);
    }
    const sim_run_step = b.step("simulator", "Run the simulator (audio file + reference output)");
    sim_run_step.dependOn(&sim_run_artifact.step);

    //
    // dbsim executable  - Runs VAD against pre-cached data from DuckDB
    //
    const dbsim_exe = b.addExecutable(.{
        .name = "dbsim",
        .root_source_file = .{ .path = "src/simulator-db.zig" },
        .target = target,
        .optimize = optimize,
    });
    try addClap(dbsim_exe, common_options);
    try addOnnx(dbsim_exe, common_options);
    try addDeepFilterNet(dbsim_exe, common_options);
    try addDuckDb(dbsim_exe, common_options);

    const dbsim_exe_install = b.addInstallArtifact(dbsim_exe, .{});
    b.getInstallStep().dependOn(&dbsim_exe_install.step);

    const dbsim_run_artifact = b.addRunArtifact(dbsim_exe);
    dbsim_run_artifact.step.dependOn(&dbsim_exe_install.step);
    if (b.args) |args| {
        dbsim_run_artifact.addArgs(args);
    }
    const dbsim_run_step = b.step("dbsim", "Run the simulator (DuckDB input)");
    dbsim_run_step.dependOn(&dbsim_run_artifact.step);
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

fn addOnnx(exe: *Build.Step.Compile, options: CommonOptions) !void {
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
    const src_path = onnx_dep.module("onnxruntime_lib").root_source_file.?.getPath(b);
    const dst_path = try std.fs.path.join(b.allocator, &.{ b.install_path, "bin", "lib" });

    // const install_onnx_libs = options.build.addInstallDirectory(.{
    //     .source_dir = .{ .path = src_path },
    //     .install_dir = .bin,
    //     .install_subdir = "lib",
    // });
    // install.step.dependOn(&install_onnx_libs.step);

    const install_onnx_symlinks = copySharedObjectsWithSymlinks(b, src_path, dst_path);
    exe.step.dependOn(&install_onnx_symlinks.step);
}

// var build_dfn: ?*Build.Step.Run = null;
var dfn_installed = false;
fn addDeepFilterNet(exe: *Build.Step.Compile, options: CommonOptions) !void {
    const b = options.build;

    const dfn_dep = b.dependency("deepfilternet", .{});

    exe.addIncludePath(dfn_dep.path("include"));

    // Linking unwind or libcpp breaks stack traces
    // exe.addObjectFile(.{ .path = ".../...../libdeepfilter.a" });
    // exe.linkLibCpp(); // either one works
    // exe.linkSystemLibrary("unwind");

    exe.addLibraryPath(dfn_dep.path("lib"));
    exe.linkSystemLibrary("deepfilter");
    exe.linkLibC();
    try setRPath(exe);

    // Copy libs to output directory
    const dst_path = try std.fs.path.join(b.allocator, &.{ b.install_path, "bin", "lib" });
    const install_dfn_libs = copySharedObjectsWithSymlinks(
        b,
        dfn_dep.path("lib").getPath(b),
        dst_path,
    );
    exe.step.dependOn(&install_dfn_libs.step);
}

fn addDuckDb(exe: *Build.Step.Compile, options: CommonOptions) !void {
    const b = options.build;
    const duckdb_release = "v0.10.1";
    const platform_dir = "linux-amd64";

    const lib_root_for_platform = b.pathJoin(&.{ b.pathFromRoot("lib"), "libduckdb", platform_dir });
    const dynlib_name = "libduckdb.so";

    // Add zuckdb driver
    {
        const zuckdb = b.dependency("zuckdb", .{
            .target = options.target,
            .optimize = options.optimize,
        }).module("zuckdb");

        zuckdb.addIncludePath(.{ .path = lib_root_for_platform });

        exe.addLibraryPath(.{ .path = lib_root_for_platform });
        exe.linkSystemLibrary("duckdb");

        exe.root_module.addImport("zuckdb", zuckdb);
        try setRPath(exe);
    }

    {
        // downloads libduckdb to `lib/` directory
        const update_lib = b.addSystemCommand(&.{
            "bash",
            b.pathFromRoot("lib/libduckdb/update.sh"),
            duckdb_release,
        });
        update_lib.expectExitCode(0);
        update_lib.has_side_effects = true;
        // _ = cmd.captureStdOut(); // This combined with has_side_effects=true results in "attempt to use null value" with 0.12.0-dev.3397+43edd53c3
        exe.step.dependOn(&update_lib.step);

        // Copy libs to output directory
        const dynlib_path = b.pathJoin(&.{ lib_root_for_platform, dynlib_name });
        const out_rel_path = b.pathJoin(&.{ "lib", dynlib_name });
        const install_shared_lib = b.addInstallBinFile(.{ .path = dynlib_path }, out_rel_path);
        install_shared_lib.step.dependOn(&update_lib.step);
        exe.step.dependOn(&install_shared_lib.step);
    }
}

fn copySharedObjectsWithSymlinks(b: *Build, src_path: []const u8, dst_path: []const u8) *Build.Step.Run {
    const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p", dst_path });
    mkdir_cmd.has_side_effects = true;
    mkdir_cmd.expectExitCode(0);

    const cp_cmd = b.addSystemCommand(&.{ "find", src_path, "-maxdepth", "1", "-iname", "*.so*", "-exec", "cp", "-df", "{}", dst_path, ";" });
    cp_cmd.has_side_effects = true;
    cp_cmd.expectExitCode(0);
    cp_cmd.step.dependOn(&mkdir_cmd.step);

    return cp_cmd;
}

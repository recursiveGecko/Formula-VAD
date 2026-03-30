const std = @import("std");
const Build = std.Build;

const CommonOptions = struct {
    build: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

fn createRootModule(options: CommonOptions, path: []const u8) *Build.Module {
    return options.build.createModule(.{
        .root_source_file = options.build.path(path),
        .target = options.target,
        .optimize = options.optimize,
    });
}

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
        .root_module = createRootModule(common_options, "src/main.zig"),
    });
    try addClap(main_exe, common_options);
    try addSndfile(main_exe, common_options);
    try addKissFFT(main_exe, common_options);
    try addOnnx(main_exe, common_options);
    try addDeepFilterNet(main_exe, common_options);
    try addDuckDb(main_exe, common_options);
    try setRPath(main_exe);

    // link build-wide install step with main_exe install
    const main_exe_install = b.addInstallArtifact(main_exe, .{});
    b.getInstallStep().dependOn(&main_exe_install.step);

    // create a run step for exe and link it to install step
    const main_run_artifact = b.addRunArtifact(main_exe);
    main_run_artifact.step.dependOn(&main_exe_install.step);

    // forward `zig build` args to `main_exe`
    if (b.args) |args| {
        main_run_artifact.addArgs(args);
    }

    // expose exe install step as subcommand "main" to `zig build`
    const main_zig_build_step = b.step("main", "Build & install the main program");
    main_zig_build_step.dependOn(&main_exe_install.step);

    //
    // formula-vad tests
    //

    const test_exe = b.addTest(.{
        .name = "formula-vad-test",
        .root_module = createRootModule(common_options, "src/main.zig"),
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
        .root_module = createRootModule(common_options, "src/Evaluator.zig"),
    });
    try addClap(eval_exe, common_options);
    try setRPath(eval_exe);

    const eval_exe_install = b.addInstallArtifact(eval_exe, .{});
    b.getInstallStep().dependOn(&eval_exe_install.step);

    const eval_zig_build_step = b.step("evaluator", "Run the evaluator (VAD output + reference output)");
    eval_zig_build_step.dependOn(&eval_exe_install.step);

    //
    // simulator executable  - Runs VAD against given audio file(s) and evaluates the results against reference file(s)
    //
    const sim_exe = b.addExecutable(.{
        .name = "simulator",
        .root_module = createRootModule(common_options, "src/simulator.zig"),
    });
    try addClap(sim_exe, common_options);
    try addSndfile(sim_exe, common_options);
    try addKissFFT(sim_exe, common_options);
    try addOnnx(sim_exe, common_options);
    try addDeepFilterNet(sim_exe, common_options);
    try addDuckDb(sim_exe, common_options);
    try setRPath(sim_exe);

    const sim_exe_install = b.addInstallArtifact(sim_exe, .{});
    b.getInstallStep().dependOn(&sim_exe_install.step);

    const sim_zig_build_step = b.step("simulator", "Build and install the simulator");
    sim_zig_build_step.dependOn(&sim_exe_install.step);

    //
    // dbsim executable  - Runs VAD against pre-cached data from DuckDB
    //
    const dbsim_exe = b.addExecutable(.{
        .name = "dbsim",
        .root_module = createRootModule(common_options, "src/simulator-db.zig"),
    });
    try addClap(dbsim_exe, common_options);
    try addKissFFT(dbsim_exe, common_options);
    try addOnnx(dbsim_exe, common_options);
    try addDeepFilterNet(dbsim_exe, common_options);
    try addDuckDb(dbsim_exe, common_options);
    try setRPath(dbsim_exe);

    const dbsim_exe_install = b.addInstallArtifact(dbsim_exe, .{});
    b.getInstallStep().dependOn(&dbsim_exe_install.step);

    const dbsim_zig_build_step = b.step("dbsim", "Build and install the DB simulator (DuckDB input)");
    dbsim_zig_build_step.dependOn(&dbsim_exe_install.step);
}

fn setRPath(exe: *Build.Step.Compile) !void {
    // Don't add compile-time absolute library paths to runtime search path
    exe.each_lib_rpath = false;

    // Executables should look for libraries in a binary-relative ./lib directory
    exe.root_module.addRPathSpecial("$ORIGIN/../lib");
}

fn addSndfile(exe: *Build.Step.Compile, options: CommonOptions) !void {
    _ = options;
    exe.root_module.linkSystemLibrary("sndfile", .{});
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
        const lib = options.build.addLibrary(.{
            .linkage = .static,
            .name = "kissfft",
            .root_module = options.build.createModule(.{
                .target = options.target,
                .optimize = options.optimize,
                .link_libc = true,
            }),
        });

        lib.root_module.addCSourceFiles(.{
            .root = kissfft_dep.path(""),
            .files = &.{
                // "kfc.c",
                "kiss_fft.c",
                // "kiss_fftnd.c",
                // "kiss_fftndr.c",
                "kiss_fftr.c",
            },
            .flags = &.{"-Wall"},
        });

        for (macros) |macro| {
            lib.root_module.addCMacro(macro[0], macro[1]);
        }

        kiss_fft_lib = lib;
    }

    exe.addIncludePath(kissfft_dep.path(""));
    exe.linkLibrary(kiss_fft_lib.?);
}

fn addOnnx(exe: *Build.Step.Compile, options: CommonOptions) !void {
    const b = options.build;
    const zig_onnx_dep = b.dependency("onnxruntime_zig", .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const onnxruntime_dep = b.dependency("onnxruntime_linux_x64", .{});

    exe.root_module.addImport("onnxruntime", zig_onnx_dep.module("onnxruntime"));

    //
    // onnxruntime shared library
    //
    exe.root_module.addLibraryPath(onnxruntime_dep.path("lib"));
    exe.linkLibC();
    exe.root_module.linkSystemLibrary("onnxruntime", .{});

    // Copy libs to output directory
    const install_shared_lib = b.addInstallLibFile(
        onnxruntime_dep.path("lib/libonnxruntime.so.1"),
        "libonnxruntime.so.1",
    );
    exe.step.dependOn(&install_shared_lib.step);
}

// var build_dfn: ?*Build.Step.Run = null;
var dfn_installed = false;
fn addDeepFilterNet(exe: *Build.Step.Compile, options: CommonOptions) !void {
    const b = options.build;

    const dfn_dep = b.dependency("deepfilternet", .{});

    exe.addIncludePath(dfn_dep.path("include"));

    // Statically linking with libdeepfilter requires `unwind` or `libcpp`, both of which break stack traces
    // exe.addObjectFile(.{ .path = ".../...../libdeepfilter.a" });
    // exe.root_module.linkLibCpp(); // either one works
    // exe.root_module.linkSystemLibrary("unwind");

    exe.root_module.addLibraryPath(dfn_dep.path("lib"));
    exe.root_module.linkSystemLibrary("deepfilter", .{});
    exe.root_module.link_libc = true;

    // Copy libs to output directory
    {
        const install_shared_lib = b.addInstallLibFile(
            dfn_dep.path("lib/libdeepfilter.so.0.5"),
            "libdeepfilter.so.0.5",
        );
        exe.step.dependOn(&install_shared_lib.step);
    }
}

fn addDuckDb(exe: *Build.Step.Compile, options: CommonOptions) !void {
    const b = options.build;

    // Add DuckDB library
    const duckdb_variant = "linux_x64";
    const duckdb_dep = b.dependency("duckdb_" ++ duckdb_variant, .{});

    // Add zuckdb driver
    {
        const zuckdb = b.dependency("zuckdb", .{
            .target = options.target,
            .optimize = options.optimize,
        }).module("zuckdb");

        zuckdb.addIncludePath(duckdb_dep.path(""));

        exe.root_module.addLibraryPath(duckdb_dep.path(""));
        exe.root_module.linkSystemLibrary("duckdb", .{});
        exe.root_module.addImport("zuckdb", zuckdb);
    }

    {
        const install_shared_lib = b.addInstallLibFile(
            duckdb_dep.path("libduckdb.so"),
            "libduckdb.so",
        );
        exe.step.dependOn(&install_shared_lib.step);
    }
}

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

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common_options = CommonOptions{
        .target = target,
        .optimize = optimize,
    };

    var zbor_module = b.createModule(.{
        .source_file = .{ .path = "lib/zbor/src/main.zig" },
    });

    var websocket_module = b.createModule(.{
        .source_file = .{ .path = "lib/websocket/src/websocket.zig" },
    });

    const exe = b.addExecutable(.{
        .name = "analyzer",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("zbor", zbor_module);
    exe.addModule("websocket", websocket_module);
    // try addZigGameDev(b, exe, common_options);
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

    const unit_tests = b.addTest(.{
        .name = "analyzer-test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    // try addZigGameDev(b, unit_tests, common_options);
    try addKissFFT(b, unit_tests, common_options);
    try addKissFFT(b, unit_tests, common_options);
    try addRnnoise(b, unit_tests, common_options);

    b.installArtifact(unit_tests);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn addKissFFT(b: *std.Build, exe: *std.Build.Step.Compile, options: CommonOptions) !void {
    const macros: []const KV = &.{
        .{ "kiss_fft_scalar", "float" },
    };

    const source_files = try prefixedPaths(b.allocator, "lib/kissfft", &.{
        // "kfc.c",
        "kiss_fft.c",
        // "kiss_fftnd.c",
        // "kiss_fftndr.c",
        "kiss_fftr.c",
    });

    var kissfft_lib = b.addStaticLibrary(.{
        .name = "kissfft",
        .optimize = options.optimize,
        .target = options.target,
    });
    kissfft_lib.linkLibC();
    kissfft_lib.addCSourceFiles(source_files, &.{"-Wall"});

    exe.addIncludePath("lib/kissfft");
    exe.linkLibrary(kissfft_lib);

    for (macros) |macro| {
        kissfft_lib.defineCMacro(macro.k(), macro.v());
        exe.defineCMacro(macro.k(), macro.v());
    }
}

fn addRnnoise(b: *std.Build, exe: *std.Build.Step.Compile, options: CommonOptions) !void {
    const rnnSources = try prefixedPaths(b.allocator, "lib/rnnoise/src", &.{
        "denoise.c",
        "celt_lpc.c",
        "kiss_fft.c",
        "pitch.c",
        "rnn_data.c",
        "rnn_reader.c",
        "rnn.c",
    });

    const rnnoiseLib = b.addStaticLibrary(.{
        .name = "rnnoise",
        .target = options.target,
        .optimize = options.optimize,
    });
    rnnoiseLib.addCSourceFiles(rnnSources, &.{});
    rnnoiseLib.linkLibC();
    rnnoiseLib.addIncludePath("lib/rnnoise/include");

    exe.linkLibrary(rnnoiseLib);
    exe.addIncludePath("lib/rnnoise/include");
}

fn addSndfile(b: *std.Build, exe: *std.Build.Step.Compile, options: CommonOptions) !void {
    _ = options;
    _ = b;
    exe.linkSystemLibrary("sndfile");
}

// fn addZigGameDev(b: *std.Build, exe: *std.Build.Step.Compile, options: CommonOptions) !void {
//     const zgui = @import("lib/zig-gamedev/libs/zgui/build.zig");
//     const zglfw = @import("lib/zig-gamedev/libs/zglfw/build.zig");
//     const zgpu = @import("lib/zig-gamedev/libs/zgpu/build.zig");
//     const zpool = @import("lib/zig-gamedev/libs/zpool/build.zig");

//     const target = options.target;
//     const optimize = options.optimize;

//     const zgui_pkg = zgui.package(b, target, optimize, .{
//         .options = .{
//             .backend = .glfw_wgpu,
//         },
//     });
//     zgui_pkg.link(exe);

//     // Needed for glfw/wgpu rendering backend
//     const zglfw_pkg = zglfw.package(b, target, optimize, .{});
//     const zpool_pkg = zpool.package(b, target, optimize, .{});
//     const zgpu_pkg = zgpu.package(b, target, optimize, .{
//         .deps = .{
//             .zpool = zpool_pkg.zpool,
//             .zglfw = zglfw_pkg.zglfw,
//         },
//     });

//     zglfw_pkg.link(exe);
//     zgpu_pkg.link(exe);
// }

fn prefixedPaths(allocator: std.mem.Allocator, prefix: []const u8, paths: []const []const u8) ![][]const u8 {
    const prefixed_paths = try allocator.alloc([]const u8, paths.len);

    for (paths, 0..) |path, i| {
        prefixed_paths[i] = try std.fs.path.joinZ(allocator, &.{ prefix, path });
    }

    return prefixed_paths;
}

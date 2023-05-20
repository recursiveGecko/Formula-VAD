const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const VAD = @import("AudioPipeline/VAD.zig");
const clap = @import("clap");
const Evaluator = @import("Evaluator.zig");
const SimulationInstance = @import("./simulator/SimulationInstance.zig");
const report_generator = @import("./simulator/report_generator.zig");

const Thread = std.Thread;
const fs = std.fs;
const log = std.log.scoped(.simulator);
const exit = std.os.exit;
const stderr = std.io.getStdErr();
const stdout = std.io.getStdOut();
const stderr_w = stdout.writer();
const stdout_w = stdout.writer();
const megabyte = 1024 * 1024;
const seconds_per_hour = 3600;

/// stdlib option overrides
pub const std_options = struct {
    pub const log_level = .info;
    pub const log_scope_levels = &.{
        .{
            .scope = .vad,
            .level = .info,
        },
    };
};

const StaticSimConfig = struct {
    verbose_allocation_log: bool = false,
};
pub const static_sim_config = StaticSimConfig{};

pub const DynamicSimConfig = struct {
    vad_config: ?VAD.Config = null,
    output_dir: ?[]const u8 = null,

    /// Whether to preload audio into memory or stream it
    preload_audio: bool = false,
    /// Number of audio samples to read at a time when streaming audio
    audio_read_frame_count: usize = 48000,
};

pub const Simulation = struct {
    allocator: Allocator,
    instances: []SimulationInstance,
    config: DynamicSimConfig = .{},
    original_json: SimulationJSON,

    pub fn deinit(self: *@This()) void {
        std.json.parseFree(SimulationJSON, self.allocator, self.original_json);
    }
};

pub const SimulationJSON = struct {
    instances: []SimulationInstanceJSON,
    config: DynamicSimConfig = .{},
};

pub const SimulationInstanceJSON = struct {
    name: []const u8,
    audio_path: []const u8,
    ref_path: []const u8,
};

const cli_params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit
    \\-i, --input <str>      Simulation plan (path to JSON)
    \\
);

fn printHelp() !void {
    try clap.help(stdout_w, clap.Help, &cli_params, .{});
}

/// Entrypoint for CLI invocation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &cli_params, clap.parsers.default, .{
        .diagnostic = &diag,
    }) catch |err| {
        try printHelp();
        diag.report(stderr.writer(), err) catch {};
        exit(1);
    };
    defer res.deinit();

    if (res.args.help == 1) {
        try printHelp();
        return;
    }

    if (res.args.input == null) {
        try printHelp();
        return;
    }

    const plan_json_path = res.args.input.?;

    // Initialize and run the simulation
    var simulation = initialize(allocator, plan_json_path) catch |err| {
        try stderr_w.print("Failed to initialize simulation: {}\n", .{err});
        exit(1);
    };
    defer simulation.deinit();

    try runAll(allocator, simulation);
    const report = try report_generator.bufPrintSimulationReport(allocator, simulation.*);
    defer allocator.free(report);
    try stdout_w.writeAll(report);
}

pub fn initialize(allocator: Allocator, json_path: []const u8) !*Simulation {
    const plan_contents = try fs.Dir.readFileAlloc(fs.cwd(), allocator, json_path, 10 * megabyte);
    errdefer allocator.free(plan_contents);

    const plan_json: SimulationJSON = try std.json.parseFromSlice(SimulationJSON, allocator, plan_contents, .{
        .ignore_unknown_fields = true,
    });

    var instances = try allocator.alloc(SimulationInstance, plan_json.instances.len);
    var instances_alloc: usize = 0;
    errdefer {
        for (0..instances_alloc) |i| instances[i].deinit();
        allocator.free(instances);
    }

    for (plan_json.instances, 0..) |instance_json, i| {
        instances[i] = try SimulationInstance.init(allocator, json_path, instance_json, plan_json.config);
        instances_alloc += 1;
    }

    var simulation = try allocator.create(Simulation);
    errdefer allocator.destroy(simulation);

    simulation.* = Simulation{
        .instances = instances,
        .config = plan_json.config,
        .original_json = plan_json,
        .allocator = allocator,
    };

    return simulation;
}

pub fn runAll(allocator: Allocator, simulation: *Simulation) !void {
    var threads = try allocator.alloc(Thread, simulation.instances.len);
    errdefer allocator.free(threads);

    for (simulation.instances, 0..) |*instance, i| {
        threads[i] = try Thread.spawn(.{}, SimulationInstance.run, .{instance});
    }

    for (threads) |thread| {
        thread.join();
    }
}

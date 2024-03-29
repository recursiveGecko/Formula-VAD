const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const clap = @import("clap");
const Evaluator = @import("Evaluator.zig");
const SimulationInstance = @import("./simulator/SimulationInstance.zig");
const AudioPipeline = @import("./AudioPipeline.zig");
const DataLogger = @import("./DataLogger.zig");
const report_generator = @import("./simulator/report_generator.zig");

const Thread = std.Thread;
const fs = std.fs;
const log = std.log.scoped(.simulator);
const exit = std.process.exit;
const stderr = std.io.getStdErr();
const stdout = std.io.getStdOut();
const stderr_w = stdout.writer();
const stdout_w = stdout.writer();
const megabyte = 1024 * 1024;
const seconds_per_hour = 3600;

/// stdlib option overrides
pub const std_options: std.Options = .{
    .log_level = .warn,
    .log_scope_levels = &.{
        .{ .scope = .vad_sm, .level = .warn },
        .{ .scope = .vad, .level = .warn },
    },
};

/// Hardcoded simulator config
const StaticSimConfig = struct {
    verbose_allocation_log: bool = false,
    stat_config: Evaluator.statistics.StatConfig = .{
        // Should be overriden during evaluation to match VAD machine config
        .ignore_shorter_than_sec = 999999,
        .extrude_start = 3,
        .extrude_end = 2,
        .fill_gaps = 3,
    },
};
pub const static_sim_config = StaticSimConfig{};

/// Simulator config read from plan.json
pub const DynamicSimConfig = struct {
    pre_vad_config: AudioPipeline.Config.PreVADConfig = .{},
    vad_config: AudioPipeline.Config.VADConfig = .{},
    output_dir: ?[]const u8 = null,
};

pub const Simulation = struct {
    instances: []SimulationInstance,
    config: DynamicSimConfig = .{},
    resolved_out_path: ?[]const u8,
    data_logger: ?DataLogger,

    pub fn deinit(self: *@This()) void {
        if (self.data_logger) |*dl| dl.deinit();
        for (self.instances) |*instance| instance.deinit();
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

pub const CLIArgs = struct {
    plan_json_path: []const u8,
    record: AudioPipeline.Config.RecordingTarget,
    data_logger_enabled: bool,
};

const cli_params = clap.parseParamsComptime(
    \\-h, --help               Display this help and exit
    \\-i, --input    <str>     Simulation plan (path to JSON)
    \\-r, --record   <record>  Select which audio to record (all, original, none)
    \\    --data-log           Enable data logging to .parquet file
    \\
);

fn printHelp() !void {
    try clap.help(stdout_w, clap.Help, &cli_params, .{});
}

/// Entrypoint for CLI invocation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var unsafe_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    var thread_safe_arena = std.heap.ThreadSafeAllocator{ .child_allocator = unsafe_arena.allocator() };
    const arena_alloc = thread_safe_arena.allocator();
    defer unsafe_arena.deinit();

    const arg_parsers = .{
        .str = clap.parsers.string,
        .record = clap.parsers.enumeration(AudioPipeline.Config.RecordingTarget),
    };

    var diag = clap.Diagnostic{};
    const res = clap.parse(clap.Help, &cli_params, arg_parsers, .{
        .allocator = arena_alloc,
        .diagnostic = &diag,
    }) catch |err| {
        try printHelp();
        diag.report(stderr.writer(), err) catch {};
        exit(1);
    };

    if (res.args.help == 1) {
        try printHelp();
        return;
    }

    if (res.args.input == null) {
        try printHelp();
        return;
    }

    const cli_args = CLIArgs{
        .record = res.args.record orelse .none,
        .plan_json_path = res.args.input.?,
        .data_logger_enabled = res.args.@"data-log" == 1,
    };

    // Initialize and run the simulation

    var simulation = initialize(arena_alloc, gpa.allocator(), cli_args) catch |err| {
        try stderr_w.print("Failed to initialize simulation: {}\n", .{err});
        exit(1);
    };
    defer simulation.deinit();

    try runAll(arena_alloc, simulation);

    const results = try arena_alloc.alloc(Evaluator.Result, simulation.instances.len);
    for (simulation.instances, 0..) |instance, i| {
        results[i] = instance.eval_result.?;
    }

    const report = try report_generator.bufPrintSimulationReport(arena_alloc, results, .plain);

    try stdout_w.writeAll(report);

    // Generate output and report
    _ = try maybeSaveOutput(arena_alloc, simulation);

    // Save report
    const report_path = try std.fs.path.join(arena_alloc, &.{ simulation.resolved_out_path.?, "report.txt" });
    try std.fs.Dir.writeFile(fs.cwd(), report_path, report);
}

pub fn initialize(arena_alloc: Allocator, gpa_alloc: Allocator, cli_args: CLIArgs) !*Simulation {
    const plan_path = cli_args.plan_json_path;
    const plan_dir_path = fs.path.dirname(plan_path) orelse ".";

    // Read and parse the simulation plan JSON
    const plan_contents = try fs.Dir.readFileAlloc(fs.cwd(), arena_alloc, plan_path, 10 * megabyte);

    const plan_json = try std.json.parseFromSlice(SimulationJSON, arena_alloc, plan_contents, .{
        .ignore_unknown_fields = true,
    });

    // If output dir was specified, create a timestamped output directory for this simulation
    const resolved_out_path: ?[]const u8 = val: {
        if (plan_json.value.config.output_dir) |out_dir| {
            const subdir_name = try std.fmt.allocPrint(arena_alloc, "{d}", .{std.time.timestamp()});
            const subdir_path = try fs.path.resolve(arena_alloc, &.{ plan_dir_path, out_dir, subdir_name });

            try fs.Dir.makePath(fs.cwd(), subdir_path);
            break :val subdir_path;
        } else {
            break :val null;
        }
    };

    var data_logger: ?DataLogger = null;

    // Maybe copy the plan JSON to the output directory and initialize DataLogger
    if (resolved_out_path) |out_dir| {
        const json_copy_path = try fs.path.join(arena_alloc, &.{ out_dir, "plan.json" });
        try fs.Dir.writeFile(fs.cwd(), json_copy_path, plan_contents);

        // Initialize data logger
        if (cli_args.data_logger_enabled) {
            const data_log_path = try fs.path.resolve(arena_alloc, &.{ out_dir, "data-log.duckdb" });
            data_logger = try DataLogger.open(gpa_alloc, data_log_path);
            // data_logger = try DataLogger.open(gpa_alloc, ":memory:");
            try data_logger.?.createTables();
        }
    }

    // Allocate instances
    var instances = try arena_alloc.alloc(SimulationInstance, plan_json.value.instances.len);

    // Initialize instances, maybe creating output directories for each
    for (plan_json.value.instances, 0..) |instance_json, i| {
        const out_dir = val: {
            if (resolved_out_path == null) break :val null;
            // If we're not recording audio, we don't need the output dir
            if (cli_args.record == .none) break :val null;

            const instance_out_dir = try fs.path.resolve(arena_alloc, &.{ resolved_out_path.?, instance_json.name });
            try fs.Dir.makePath(fs.cwd(), instance_out_dir);
            break :val instance_out_dir;
        };

        var stat_config = static_sim_config.stat_config;
        stat_config.ignore_shorter_than_sec = plan_json.value.config.vad_config.min_speech_duration_ms / 1000;

        const opts = SimulationInstance.Opts{
            .base_path = plan_dir_path,
            .output_dir = out_dir,
            .instance_json = instance_json,
            .sim_config = plan_json.value.config,
            .cli_args = cli_args,
            .data_logger = data_logger,
            .stat_config = stat_config,
        };

        instances[i] = try SimulationInstance.init(arena_alloc, opts);
    }

    const simulation = try arena_alloc.create(Simulation);

    simulation.* = Simulation{
        .instances = instances,
        .config = plan_json.value.config,
        .resolved_out_path = resolved_out_path,
        .data_logger = data_logger,
    };

    return simulation;
}

pub fn runAll(arena_alloc: Allocator, simulation: *Simulation) !void {
    var threads = try arena_alloc.alloc(Thread, simulation.instances.len);

    for (simulation.instances, 0..) |*instance, i| {
        threads[i] = try Thread.spawn(.{}, SimulationInstance.run, .{instance});
    }

    for (threads) |thread| {
        thread.join();
    }
}

pub fn maybeSaveOutput(arena_alloc: Allocator, simulation: *const Simulation) !bool {
    if (simulation.resolved_out_path == null) return false;
    const out_dir = simulation.resolved_out_path.?;

    for (simulation.instances) |instance| {
        if (instance.eval_result == null) {
            log.warn("Not saving output of instance {s} because it doesn't contain a result\n", .{instance.name});
            return false;
        }

        const audacity_filename = try std.fmt.allocPrint(arena_alloc, "{s}-audacity.txt", .{instance.name});
        const audacity_path = try fs.path.join(arena_alloc, &.{ out_dir, audacity_filename });
        const audacity_txt = try Evaluator.formats.serializeResultToAudacity(arena_alloc, instance.eval_result.?);

        fs.Dir.writeFile(fs.cwd(), audacity_path, audacity_txt) catch |err| {
            log.err("Failed to write Audacity txt: {any}", .{err});
            return false;
        };

        log.info("{s}: Wrote Audacity txt to {s}", .{ instance.name, audacity_path });
    }

    return true;
}

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
    vad_config: VAD.Config = .{},
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
    base_path: []const u8,
    resolved_out_path: ?[]const u8,

    pub fn deinit(self: *@This()) void {
        std.json.parseFree(SimulationJSON, self.allocator, self.original_json);
        if (self.resolved_out_path) |path| self.allocator.free(path);
        for (self.instances) |*instance| instance.deinit();
        self.allocator.free(self.instances);
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

    // Generate output and report
    _ = try maybeSaveOutput(allocator, simulation);

    const stat_config = Evaluator.statistics.StatConfig{
        .ignore_shorter_than_sec = simulation.config.vad_config.vad_machine_config.min_vad_duration_sec,
    };

    const report = try report_generator.bufPrintSimulationReport(allocator, simulation.*, stat_config);
    defer allocator.free(report);
    try stdout_w.writeAll(report);
}

pub fn initialize(allocator: Allocator, json_path: []const u8) !*Simulation {
    const base_path = fs.path.dirname(json_path) orelse ".";

    // Read and parse the simulation plan JSON
    const plan_contents = try fs.Dir.readFileAlloc(fs.cwd(), allocator, json_path, 10 * megabyte);
    defer allocator.free(plan_contents);

    const plan_json: SimulationJSON = try std.json.parseFromSlice(SimulationJSON, allocator, plan_contents, .{
        .ignore_unknown_fields = true,
    });

    // If output dir was specified, create a timestamped output directory for this simulation
    var resolved_out_path: ?[]const u8 = val: {
        if (plan_json.config.output_dir) |out_dir| {
            const subdir_name = try std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()});
            const subdir_path = try fs.path.resolve(allocator, &.{ base_path, out_dir, subdir_name });
            defer allocator.free(subdir_name);

            try fs.Dir.makePath(fs.cwd(), subdir_path);
            break :val subdir_path;
        } else {
            break :val null;
        }
    };
    errdefer if (resolved_out_path) |path| allocator.free(path);

    // Maybe copy the plan JSON to the output directory
    if (resolved_out_path) |out_dir| {
        const json_copy_path = try fs.path.join(allocator, &.{ out_dir, "plan.json" });
        defer allocator.free(json_copy_path);
        try fs.Dir.writeFile(fs.cwd(), json_copy_path, plan_contents);
    }

    // Allocate instances
    var instances = try allocator.alloc(SimulationInstance, plan_json.instances.len);
    var instances_alloc: usize = 0;
    errdefer {
        for (0..instances_alloc) |i| instances[i].deinit();
        allocator.free(instances);
    }

    // Initialize instances, maybe creating output directories for each
    for (plan_json.instances, 0..) |instance_json, i| {
        var out_dir = val: {
            if (resolved_out_path == null) break :val null;

            const instance_out_dir = try fs.path.resolve(allocator, &.{ resolved_out_path.?, instance_json.name });
            try fs.Dir.makePath(fs.cwd(), instance_out_dir);
            break :val instance_out_dir;
        };

        instances[i] = try SimulationInstance.init(
            allocator,
            base_path,
            out_dir,
            instance_json,
            plan_json.config,
        );
        instances_alloc += 1;
    }

    var simulation = try allocator.create(Simulation);
    errdefer allocator.destroy(simulation);

    simulation.* = Simulation{
        .instances = instances,
        .config = plan_json.config,
        .original_json = plan_json,
        .base_path = base_path,
        .resolved_out_path = resolved_out_path,
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

pub fn maybeSaveOutput(allocator: Allocator, simulation: *const Simulation) !bool {
    if (simulation.resolved_out_path == null) return false;
    const out_dir = simulation.resolved_out_path.?;

    for (simulation.instances) |instance| {
        if (instance.evaluator == null) {
            log.warn("Not saving output of instance {s} because it doesn't contain a result\n", .{instance.name});
        }

        const audacity_filename = try std.fmt.allocPrint(allocator, "{s}-audacity.txt", .{instance.name});
        defer allocator.free(audacity_filename);
        const audacity_path = try fs.path.join(allocator, &.{ out_dir, audacity_filename });
        defer allocator.free(audacity_path);

        const audacity_txt = try Evaluator.formats.serializeEvaluatorToAudacityTxt(allocator, instance.evaluator.?);
        defer allocator.free(audacity_txt);

        fs.Dir.writeFile(fs.cwd(), audacity_path, audacity_txt) catch |err| {
            log.err("Failed to write Audacity txt: {any}", .{err});
            return false;
        };

        log.info("{s}: Wrote Audacity txt to {s}", .{ instance.name, audacity_path });
    }

    return true;
}

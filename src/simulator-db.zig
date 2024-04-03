const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const clap = @import("clap");
const Evaluator = @import("Evaluator.zig");
const simulator = @import("simulator.zig");
const AudioPipeline = @import("./AudioPipeline.zig");
const SileroVADMachine = @import("./AudioPipeline/SileroVADMachine.zig");
const audio_utils = @import("./audio_utils.zig");
const DataLogger = @import("./DataLogger.zig");
const report_generator = @import("./simulator/report_generator.zig");

const Thread = std.Thread;
const fs = std.fs;
const log = std.log.scoped(.db_simulator);
const exit = std.process.exit;
const stderr = std.io.getStdErr();
const stdout = std.io.getStdOut();
const stderr_w = stdout.writer();
const stdout_w = stdout.writer();
const megabyte = 1024 * 1024;

/// stdlib option overrides
pub const std_options: std.Options = .{
    .log_level = .warn,
    .log_scope_levels = &.{
        .{ .scope = .vad_sm, .level = .warn },
        .{ .scope = .vad, .level = .warn },
    },
    .fmt_max_depth = 4,
};

pub const SimulationConfigJSON = struct {
    vad_config: AudioPipeline.Config.VADConfig = .{},
    output_dir: []const u8,
};

pub const DBSimulationInstance = struct {
    stream_info: DataLogger.StreamInfo,
    ref_segments: []Evaluator.SpeechSegment,
    evaluator: ?Evaluator = null,
};

pub const Simulation = struct {
    instances: []DBSimulationInstance,
    config: SimulationConfigJSON,
};

pub const CLIArgs = struct {
    database_path: []const u8,
    config_path: []const u8,
};

const cli_params = clap.parseParamsComptime(
    \\-h, --help               Display this help and exit
    \\-d, --database <str>     DuckDB database
    \\-c, --config   <str>     Simulation configuration
);

fn printHelp() !void {
    try clap.help(stdout_w, clap.Help, &cli_params, .{});
}

/// Entrypoint for CLI invocation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const arg_parsers = .{
        .str = clap.parsers.string,
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

    if (res.args.database == null) {
        try printHelp();
        return;
    }

    if (res.args.config == null) {
        try printHelp();
        return;
    }

    const cli_args = CLIArgs{
        .config_path = res.args.config.?,
        .database_path = res.args.database.?,
    };

    // Initialize and run the simulation
    var db = try DataLogger.open(gpa.allocator(), cli_args.database_path, .{ .read_only = true });
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    var sim = try initialize(arena_alloc, conn, cli_args);
    try stderr_w.print("Using config: {any}\n", .{sim.config});

    var eval_results = try arena_alloc.alloc(Evaluator.Result, sim.instances.len);
    for (sim.instances, 0..) |*instance, i| {
        eval_results[i] = try runInstance(arena_alloc, conn, &sim, instance);
    }

    const report = try report_generator.bufPrintSimulationReport(arena_alloc, eval_results, .plain);

    try stdout_w.writeAll(report);

    // // Generate output and report
    // _ = try maybeSaveOutput(arena_alloc, simulation);

    // // Save report
    // const report_path = try std.fs.path.join(arena_alloc, &.{ simulation.resolved_out_path.?, "report.txt" });
    // try std.fs.Dir.writeFile(fs.cwd(), report_path, report);
}

fn initialize(arena_alloc: std.mem.Allocator, conn: *DataLogger.Conn, cli_args: CLIArgs) !Simulation {
    // Find all StreamInfos
    const all_stream_infos = val: {
        var list = std.ArrayList(DataLogger.StreamInfo).init(arena_alloc);

        // Fetch in batches of 25
        var last_id: ?i32 = null;
        var temp: [25]DataLogger.StreamInfo = undefined;
        while (true) {
            const db_slice = try conn.findStreamInfo(arena_alloc, &temp, last_id);

            if (db_slice.len == 0) break;
            last_id = db_slice[db_slice.len - 1].id;

            const list_slice = try list.addManyAsSlice(db_slice.len);
            @memcpy(list_slice, db_slice);
        }

        break :val try list.toOwnedSlice();
    };
    const instances = try arena_alloc.alloc(DBSimulationInstance, all_stream_infos.len);

    // Initialize each instance
    for (all_stream_infos, 0..) |stream_info, i| {
        const sample_rate_f: f32 = @floatFromInt(stream_info.sample_rate);

        // Find all reference segments
        const ref_segments = val: {
            var list = std.ArrayList(Evaluator.SpeechSegment).init(arena_alloc);

            // Fetch in batches of 25
            var last_id: ?i32 = null;
            var temp: [25]DataLogger.RefSegment = undefined;
            while (true) {
                const db_slice = try conn.findRefSegments(stream_info.id.?, &temp, last_id);

                if (db_slice.len == 0) break;
                last_id = db_slice[db_slice.len - 1].id;

                const list_slice = try list.addManyAsSlice(db_slice.len);
                for (db_slice, 0..) |ref_segment, i_seg| {
                    list_slice[i_seg] = Evaluator.SpeechSegment{
                        .side = .ref,
                        .from_sec = @as(f32, @floatFromInt(ref_segment.from_sample)) / sample_rate_f,
                        .to_sec = @as(f32, @floatFromInt(ref_segment.to_sample)) / sample_rate_f,
                    };
                }
            }

            break :val try list.toOwnedSlice();
        };

        instances[i] = DBSimulationInstance{
            .stream_info = stream_info,
            .ref_segments = ref_segments,
        };
    }

    // Read and parse the config JSON
    const plan_contents = fs.Dir.readFileAlloc(fs.cwd(), arena_alloc, cli_args.config_path, 10 * megabyte) catch |err| {
        std.debug.panic("Unable to read config JSON from '{s}': {any}", .{ cli_args.config_path, err });
    };
    const config_json = try std.json.parseFromSlice(SimulationConfigJSON, arena_alloc, plan_contents, .{
        .ignore_unknown_fields = true,
    });

    return Simulation{
        .config = config_json.value,
        .instances = instances,
    };
}

fn runInstance(
    arena_alloc: std.mem.Allocator,
    conn: *DataLogger.Conn,
    sim: *Simulation,
    instance: *DBSimulationInstance,
) !Evaluator.Result {
    var silero_vad_machine = try SileroVADMachine.init(
        arena_alloc,
        sim.config.vad_config,
        1,
        instance.stream_info.sample_rate,
    );
    defer silero_vad_machine.deinit();

    var frame_length: ?u64 = null;

    var last_sample: ?u64 = null;
    var vad_data_temp: [100_000]DataLogger.VADData = undefined;

    while (true) {
        // Read VAD data
        const vad_data = try conn.findVADData(instance.stream_info.id.?, &vad_data_temp, last_sample);
        if (vad_data.len == 0) break;
        if (frame_length == null) frame_length = vad_data[1].sample_number - vad_data[0].sample_number;

        last_sample = vad_data[vad_data.len - 1].sample_number;

        // Run Silero VAD Machine
        for (vad_data) |sample| {
            const metrics = SileroVADMachine.FrameMetrics{
                .first_sample_index = sample.sample_number,
                .length = frame_length.?,
                .vad = sample.silero_vad,
            };
            _ = try silero_vad_machine.run2(metrics);
        }
    }

    // Evaluate results
    const result = val: {
        const vad_segments = try silero_vad_machine.vad_segments.toOwnedSlice();
        var speech_segments = try arena_alloc.alloc(Evaluator.SpeechSegment, vad_segments.len);

        const sample_rate = instance.stream_info.sample_rate;

        for (vad_segments, 0..) |vad_segment, i| {
            speech_segments[i] = Evaluator.SpeechSegment{
                .side = .vad,
                .from_sec = audio_utils.sampleNumberToSeconds(vad_segment.sample_from, sample_rate),
                .to_sec = audio_utils.sampleNumberToSeconds(vad_segment.sample_to, sample_rate),
                .debug_info = null,
            };
        }

        var stat_config = simulator.static_sim_config.stat_config;
        stat_config.ignore_shorter_than_sec = silero_vad_machine.config.min_speech_duration_ms / 1000;

        var result = try Evaluator.evaluate(arena_alloc, stat_config, speech_segments, instance.ref_segments);
        result.name = instance.stream_info.name;

        break :val result;
    };

    return result;
}

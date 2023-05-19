const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const AudioPipeline = @import("AudioPipeline.zig");
const AudioFileStream = @import("audio_utils/AudioFileStream.zig");
const AudioBuffer = @import("audio_utils/AudioBuffer.zig");
const AudioSource = @import("audio_utils/AudioSource.zig").AudioSource;
const VAD = @import("AudioPipeline/VAD.zig");
const clap = @import("clap");
const Evaluator = @import("Evaluator.zig");
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

// Number of audio samples to read at a time when streaming audio
const audio_read_frame_size = 48000 * 10;
// Whether to preload audio into memory or stream it
const preload_audio = false;
const verbose_allocation_log = false;

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

const SimulationJSON = struct {
    instances: []SimulationInstanceJSON,
    vad_config: ?VAD.Config = null,
    output_dir: ?[]const u8 = null,
};

const SimulationInstanceJSON = struct {
    name: []const u8,
    audio_path: []const u8,
    ref_path: []const u8,
};

const Simulation = struct {
    instances: []SimulationInstance,
};

const SimulationInstance = struct {
    name: []const u8,
    audio_source: *AudioSource,
    vad_config: VAD.Config,
    output_dir: []const u8,
    reference_segments: []const Evaluator.SpeechSegment,
    self_cleanup_allocator: Allocator,
    evaluator: ?Evaluator = null,

    pub fn deinit(self: *@This()) void {
        const alloc = self.self_cleanup_allocator;

        self.audio_source.deinit();
        alloc.destroy(self.audio_source);
        alloc.free(self.name);
        alloc.free(self.output_dir);
        alloc.free(self.reference_segments);
        if (self.evaluator) |*e| e.deinit();
    }
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

    try runAll(allocator, simulation);
    try printReport(allocator, simulation.*);
}

pub fn initialize(allocator: Allocator, json_path: []const u8) !*Simulation {
    const plan_contents = try fs.Dir.readFileAlloc(fs.cwd(), allocator, json_path, 10 * megabyte);
    errdefer allocator.free(plan_contents);

    const plan_json: SimulationJSON = try std.json.parseFromSlice(SimulationJSON, allocator, plan_contents, .{
        .ignore_unknown_fields = true,
    });
    defer std.json.parseFree(SimulationJSON, allocator, plan_json);

    var instances = try allocator.alloc(SimulationInstance, plan_json.instances.len);
    var instances_alloc: usize = 0;
    errdefer {
        for (0..instances_alloc) |i| instances[i].deinit();
        allocator.free(instances);
    }

    for (plan_json.instances, 0..) |instance_json, i| {
        instances[i] = try initializeInstance(allocator, json_path, instance_json);
        instances_alloc += 1;
    }

    var simulation = try allocator.create(Simulation);
    errdefer allocator.destroy(simulation);

    simulation.* = Simulation{
        .instances = instances,
    };

    return simulation;
}

pub fn initializeInstance(
    allocator: Allocator,
    json_path: []const u8,
    instance_json: SimulationInstanceJSON,
) !SimulationInstance {
    const name = try allocator.dupeZ(u8, instance_json.name);
    errdefer allocator.free(name);

    const json_base_path = fs.path.dirname(json_path) orelse ".";
    const audio_path = try fs.path.resolve(allocator, &.{ json_base_path, instance_json.audio_path });
    defer allocator.free(audio_path);

    const ref_path = try fs.path.resolve(allocator, &.{ json_base_path, instance_json.ref_path });
    defer allocator.free(ref_path);

    var audio_source = try allocator.create(AudioSource);
    errdefer allocator.destroy(audio_source);

    if (preload_audio) {
        const audio_buffer = try AudioBuffer.loadFromFile(allocator, audio_path);
        audio_source.* = AudioSource{ .buffer = audio_buffer };
    } else {
        const audio_stream = try AudioFileStream.open(allocator, audio_path);
        audio_source.* = AudioSource{ .stream = audio_stream };
    }

    const ref_segments = try Evaluator.readParseReferenceFile(allocator, ref_path);
    errdefer allocator.free(ref_segments);

    return SimulationInstance{
        .name = name,
        .output_dir = "",
        .audio_source = audio_source,
        .reference_segments = ref_segments,
        .vad_config = .{},
        .self_cleanup_allocator = allocator,
        .evaluator = null,
    };
}

pub fn runAll(allocator: Allocator, simulation: *Simulation) !void {
    var threads = try allocator.alloc(Thread, simulation.instances.len);
    errdefer allocator.free(threads);

    for (simulation.instances, 0..) |*instance, i| {
        threads[i] = try Thread.spawn(.{}, runInstance, .{ allocator, instance });
    }

    for (threads) |thread| {
        thread.join();
    }
}

pub fn runInstance(main_allocator: Allocator, instance: *SimulationInstance) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = verbose_allocation_log,
    }){};
    defer {
        if (builtin.mode != .Debug) _ = gpa.detectLeaks();
        _ = gpa.deinit();
    }

    var thread_allocator = gpa.allocator();

    log.info(
        "{s}: Streaming {d:.2}s from audio file. Running...",
        .{ instance.name, instance.audio_source.durationSeconds() },
    );
    var vad_segments = try simulateVAD(thread_allocator, instance.audio_source);
    defer thread_allocator.free(vad_segments);

    try storeResult(main_allocator, instance, vad_segments);
}

pub fn simulateVAD(allocator: Allocator, audio: *AudioSource) ![]VAD.VADSegment {
    const pipeline = try AudioPipeline.init(allocator, .{
        .sample_rate = audio.sampleRate(),
        .n_channels = audio.nChannels(),
        .vad_config = .{},
        // .skip_processing = true,
    });
    defer pipeline.deinit();

    // const sample_rate = audio.sampleRate();

    if (audio.* == .stream) {
        var stream = audio.stream;
        const frame_size = audio_read_frame_size;

        // Buffer where interleaved samples are temporarily stored
        var interleaved_buffer = try allocator.alloc(f32, frame_size * stream.n_channels);
        defer allocator.free(interleaved_buffer);
        // The backing slice of slices for our audio samples
        var backing_channel_pcm = try allocator.alloc([]f32, audio.nChannels());
        // The slice we'll pass to the audio pipeline, trimmed to the actual number of samples read.
        var trimmed_channel_pcm = try allocator.alloc([]f32, audio.nChannels());
        var channels_allocated: usize = 0;
        defer {
            for (0..channels_allocated) |i| allocator.free(backing_channel_pcm[i]);
            allocator.free(backing_channel_pcm);
            allocator.free(trimmed_channel_pcm);
        }
        // Initialize the backing channel slices
        for (0..backing_channel_pcm.len) |i| {
            backing_channel_pcm[i] = try allocator.alloc(f32, frame_size);
            channels_allocated += 1;
        }

        // Read frames and pass them to the AudioPipeline
        while (true) {
            const samples_read = try stream.read(interleaved_buffer, backing_channel_pcm, 0, frame_size);
            if (samples_read == 0) break;

            for (0..audio.nChannels()) |i| {
                trimmed_channel_pcm[i] = backing_channel_pcm[i][0..samples_read];
            }

            try pipeline.pushSamples(trimmed_channel_pcm);
        }
    } else if (audio.* == .buffer) {
        var audio_buffer = audio.buffer;
        try pipeline.pushSamples(audio_buffer.channel_pcm_buf);
    } else {
        unreachable;
    }

    const vad_segments = try pipeline.vad.?.vad_segments.toOwnedSlice();
    errdefer allocator.free(vad_segments);

    return vad_segments;
}

pub fn storeResult(
    main_allocator: Allocator,
    instance: *SimulationInstance,
    vad_segments: []VAD.VADSegment,
) !void {
    var speech_segments = try main_allocator.alloc(Evaluator.SpeechSegment, vad_segments.len);
    errdefer main_allocator.free(speech_segments);

    const sample_rate = instance.audio_source.sampleRate();

    for (vad_segments, 0..) |vad_segment, i| {
        const from_sec = @intToFloat(f32, vad_segment.sample_from) / @intToFloat(f32, sample_rate);
        const to_sec = @intToFloat(f32, vad_segment.sample_to) / @intToFloat(f32, sample_rate);

        const debug_info = try std.fmt.allocPrint(
            main_allocator,
            "rnn:{d:.2}% vr:{d:.2}",
            .{ vad_segment.debug_rnn_vad * 100, vad_segment.debug_avg_speech_vol_ratio },
        );

        speech_segments[i] = .{
            .from_sec = from_sec,
            .to_sec = to_sec,
            .debug_info = debug_info,
        };
    }

    instance.evaluator = try Evaluator.initAndRun(main_allocator, speech_segments, instance.reference_segments);
    errdefer instance.evaluator.deinit();
}

pub fn printReport(allocator: Allocator, simulation: Simulation) !void {
    // Aggregate results and print them
    var all_stats_list = std.ArrayList(Evaluator.Stats).init(allocator);
    errdefer all_stats_list.deinit();

    for (simulation.instances) |instance| {
        if (instance.evaluator) |e| {
            const stats = e.buildStatistics();
            try all_stats_list.append(stats);

            try stdout_w.print("\n==> {s}\n", .{instance.name});
            try stdout_w.print("Reference events:      {d: >5}\n", .{stats.total_reference_events});
            try stdout_w.print("Simulated events:      {d: >5}\n", .{stats.total_input_events});
            try stdout_w.print(
                "Correct radios  (TP):  {d: >5} ({d: >5.1}%) \n",
                .{ stats.true_positives, stats.true_positive_rate * 100 },
            );
            try stdout_w.print(
                "False radios    (FP):  {d: >5} ({d: >5.1}%) \n",
                .{ stats.false_positives, stats.false_positive_rate * 100 },
            );
            try stdout_w.print(
                "Missed radios   (FN):  {d: >5} ({d: >5.1}%) \n",
                .{ stats.false_negatives, stats.false_negative_rate * 100 },
            );
        } else {
            log.err("Instance {s} didn't return any results!", .{instance.name});
        }
    }

    const all_stats = try all_stats_list.toOwnedSlice();
    defer allocator.free(all_stats);

    const agg = Evaluator.aggregateStats(all_stats);

    try stdout_w.print("\n===== Aggregate stats =====\n\n", .{});
    try stdout_w.print("Reference events:      {d: >5}\n", .{agg.total_reference_events});
    try stdout_w.print("Simulated events:      {d: >5}\n", .{agg.total_input_events});
    try stdout_w.print(
        "Correct radios  (TP):  {d: >5} ({d: >5.1}%)  |  Min: {d: >6.2}%  Max: {d: >6.2}%  Avg: {d: >6.2}%\n",
        .{
            agg.true_positives,
            agg.true_positive_rate * 100,
            agg.min_true_positive_rate * 100,
            agg.max_true_positive_rate * 100,
            agg.avg_true_positive_rate * 100,
        },
    );
    try stdout_w.print(
        "False radios    (FP):  {d: >5} ({d: >5.1}%)  |  Min: {d: >6.2}%  Max: {d: >6.2}%  Avg: {d: >6.2}%\n",
        .{
            agg.false_positives,
            agg.false_positive_rate * 100,
            agg.min_false_positive_rate * 100,
            agg.max_false_positive_rate * 100,
            agg.avg_false_positive_rate * 100,
        },
    );
    try stdout_w.print(
        "Missed radios   (FN):  {d: >5} ({d: >5.1}%)  |  Min: {d: >6.2}%  Max: {d: >6.2}%  Avg: {d: >6.2}%\n",
        .{
            agg.false_negatives,
            agg.false_negative_rate * 100,
            agg.min_false_negative_rate * 100,
            agg.max_false_negative_rate * 100,
            agg.avg_false_negative_rate * 100,
        },
    );
}

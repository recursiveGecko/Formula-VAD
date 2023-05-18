const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioPipeline = @import("AudioPipeline.zig");
const AudioFileStream = @import("audio_utils/AudioFileStream.zig");
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

    var simulation = initialize(allocator, plan_json_path) catch |err| {
        try stderr_w.print("Failed to initialize simulation: {}\n", .{err});
        exit(1);
    };

    try runAll(allocator, simulation);

    // var out_file = if (res.args.output) |of| try fs.Dir.createFile(fs.cwd(), of, .{}) else null;

    // // Run VAD and evaluate results

    // var evaluator = try Evaluator.initAndRun(allocator, simulated_segments, ref_segments);
    // defer evaluator.deinit();

    // const stats = evaluator.buildStatistics();

    // try stdout_w.print("Statistics:\n", .{});
    // try stdout_w.print("Real events:     {}\n", .{stats.total_reference_events});
    // try stdout_w.print("VAD events:      {}\n", .{stats.total_input_events});
    // try stdout_w.print("True positives:  {}\n", .{stats.true_positives});
    // try stdout_w.print("False positives: {}\n", .{stats.false_positives});
    // try stdout_w.print("False negatives: {}\n", .{stats.false_negatives});

    // // Maybe write output segments
    // if (out_file) |out_f| {
    //     defer out_f.close();

    //     var out_fw = out_f.writer();

    //     for (evaluator.input_segments) |segment| {
    //         const comment = try segment.toComment(allocator);
    //         defer allocator.free(comment);

    //         try out_fw.print("{d:.4}\t{d:.4}\t{s}\n", .{ segment.from_sec, segment.to_sec, comment });
    //     }

    //     for (evaluator.reference_segments) |segment| {
    //         if (segment.match == .matched) continue;
    //         try out_fw.print("{d:.4}\t{d:.4}\t{s}\n", .{ segment.from_sec, segment.to_sec, "missed" });
    //     }
    // }
}

const SimulationJSON = struct {
    instances: []SimulationInstanceJSON,
    vad_config: ?VAD.Config = null,
    save_segments: bool = false,
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
    audio_stream: *AudioFileStream,
    reference_segments: []const Evaluator.SpeechSegment,
    vad_config: VAD.Config,
    output_dir: []const u8,
    result: ?[]Evaluator.SpeechSegment,
    self_cleanup_allocator: Allocator,

    pub fn deinit(self: *@This()) void {
        const alloc = self.self_cleanup_allocator;

        self.audio_stream.close();
        alloc.destroy(self.audio_stream);
        alloc.free(self.name);
        alloc.free(self.output_dir);
        alloc.free(self.reference_segments);
        if (self.result) |res| alloc.free(res);
    }
};

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

    // TODO: Maybe deallocate instances on error
    for (plan_json.instances, 0..) |instance_json, i| {
        instances[i] = try initializeInstance(allocator, json_path, instance_json);
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

    var audio_stream = try allocator.create(AudioFileStream);
    errdefer allocator.destroy(audio_stream);

    audio_stream.* = try AudioFileStream.open(allocator, audio_path);
    errdefer audio_stream.close();

    const ref_segments = try Evaluator.readParseReferenceFile(allocator, ref_path);
    errdefer allocator.free(ref_segments);

    return SimulationInstance{
        .name = name,
        .output_dir = "",
        .audio_stream = audio_stream,
        .result = null,
        .reference_segments = ref_segments,
        .vad_config = .{},
        .self_cleanup_allocator = allocator,
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    // var arena = std.heap.ArenaAllocator.init(main_allocator);
    // defer arena.deinit();

    log.info(
        "{s}: Streaming {d:.2}s from audio file. Running...",
        .{ instance.name, instance.audio_stream.durationSeconds() },
    );
    var segments = try simulateVAD(gpa.allocator(), instance.audio_stream);

    instance.result = try main_allocator.dupe(Evaluator.SpeechSegment, segments);
}

pub fn simulateVAD(allocator: Allocator, audio: *AudioFileStream) ![]Evaluator.SpeechSegment {
    const pipeline = try AudioPipeline.init(allocator, .{
        .sample_rate = audio.sample_rate,
        .n_channels = audio.n_channels,
        .vad_config = .{},
    });
    defer pipeline.deinit();

    const sample_rate = audio.sample_rate;
    const frame_size = sample_rate;

    // The backing slice of slices for our audio samples
    var backing_channel_pcm = try allocator.alloc([]f32, audio.n_channels);
    // The slice we'll pass to the audio pipeline, trimmed to the actual number of samples read.
    var trimmed_channel_pcm = try allocator.alloc([]f32, audio.n_channels);
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
    var total_samples_read: usize = 0;
    while (true) {
        const samples_read = try audio.read(backing_channel_pcm, 0, frame_size);
        if (samples_read == 0) break;

        for (0..audio.n_channels) |i| {
            trimmed_channel_pcm[i] = backing_channel_pcm[i][0..samples_read];
        }

        try pipeline.pushSamples(trimmed_channel_pcm);
        total_samples_read += samples_read;
    }

    log.info("Processed: {d} samples", .{total_samples_read});

    const vad_segments = try pipeline.vad.?.vad_segments.toOwnedSlice();
    defer allocator.free(vad_segments);

    var speech_segments = try allocator.alloc(Evaluator.SpeechSegment, vad_segments.len);
    errdefer allocator.free(speech_segments);

    for (vad_segments, 0..) |vad_segment, i| {
        const from_sec = @intToFloat(f32, vad_segment.sample_from) / @intToFloat(f32, sample_rate);
        const to_sec = @intToFloat(f32, vad_segment.sample_to) / @intToFloat(f32, sample_rate);

        const debug_info = try std.fmt.allocPrint(
            allocator,
            "rnn:{d:.2}% vr:{d:.2}",
            .{ vad_segment.debug_rnn_vad * 100, vad_segment.debug_avg_speech_vol_ratio },
        );

        speech_segments[i] = .{
            .from_sec = from_sec,
            .to_sec = to_sec,
            .debug_info = debug_info,
        };
    }

    return speech_segments;
}

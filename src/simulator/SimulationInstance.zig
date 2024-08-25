const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const audio_utils = @import("../audio_utils.zig");
const AudioPipeline = @import("../AudioPipeline.zig");
const AudioFileStream = @import("../audio_utils/AudioFileStream.zig");
const AudioBuffer = @import("../audio_utils/AudioBuffer.zig");
const AudioSource = @import("../audio_utils/AudioSource.zig").AudioSource;
const simulator = @import("../simulator.zig");
const Evaluator = @import("../Evaluator.zig");
const DataLogger = @import("../DataLogger.zig");
const static_sim_config = simulator.static_sim_config;
const SimulationInstanceJSON = simulator.SimulationInstanceJSON;
const DynamicSimConfig = simulator.DynamicSimConfig;
const log = std.log.scoped(.sim_instance);
const fs = std.fs;

const Self = @This();
const SimulationInstance = @This();

pub const Opts = struct {
    instance_json: SimulationInstanceJSON,
    /// Path of directory containing plan.json
    base_path: []const u8,
    /// Output directory for this instance
    output_dir: ?[]const u8,
    sim_config: DynamicSimConfig,
    cli_args: simulator.CLIArgs,
    data_logger: ?DataLogger,
    stat_config: Evaluator.statistics.StatConfig,
};

// Wraps the pipeline context that is required for AudioPipeline callbacks
const PipelineContext = struct {
    sim_instance: *SimulationInstance,
    allocator: Allocator,

    pub fn onRecording(
        self_opaque: *anyopaque,
        recorder_name: []const u8,
        audio_buffer: AudioBuffer,
    ) void {
        const self: *PipelineContext = @ptrCast(@alignCast(self_opaque));
        const allocator = self.allocator;

        if (self.sim_instance.opts.output_dir == null) return;
        const output_dir = self.sim_instance.opts.output_dir.?;

        const audio_file_name = std.fmt.allocPrint(
            allocator,
            "{d}-{s}.ogg",
            .{ audio_buffer.first_sample_number.?, recorder_name },
        ) catch |err| {
            log.err("Failed to allocate file name: {any}", .{err});
            return;
        };
        defer allocator.free(audio_file_name);

        const audio_path = fs.path.resolve(allocator, &.{ output_dir, audio_file_name }) catch |err| {
            log.err("Failed to allocate file path: {any}", .{err});
            return;
        };
        defer allocator.free(audio_path);

        audio_buffer.saveToFile(audio_path, AudioBuffer.Format.vorbis, 1) catch |err| {
            log.err("Failed to save file to disk: {any}", .{err});
            return;
        };

        log.debug("Saved audio: {s}", .{audio_path});
    }

    pub fn toPipelineCallbacks(self: *PipelineContext) AudioPipeline.Callbacks {
        return AudioPipeline.Callbacks{
            .ctx = self,
            .on_recording = &onRecording,
        };
    }
};

name: []const u8,
audio_stream: AudioFileStream,
reference_segments: []const Evaluator.SpeechSegment,
vad_segments: ?[]const Evaluator.SpeechSegment = null,
opts: Opts,
thread_gpa: std.heap.GeneralPurposeAllocator(.{
    .verbose_log = static_sim_config.verbose_allocation_log,
    .thread_safe = false,
}),
main_thread_allocator: Allocator,
data_logger_conn: ?*DataLogger.Conn,
eval_result: ?Evaluator.Result = null,
progress: f32 = 0,
mutex: std.Thread.Mutex = .{},

pub fn init(
    arena_alloc: Allocator,
    opts: Opts,
) !Self {
    const name = try arena_alloc.dupe(u8, opts.instance_json.name);

    const audio_path = try fs.path.resolve(arena_alloc, &.{ opts.base_path, opts.instance_json.audio_path });
    const ref_path = try fs.path.resolve(arena_alloc, &.{ opts.base_path, opts.instance_json.ref_path });

    const audio_stream = try AudioFileStream.open(arena_alloc, audio_path);
    const ref_segments = try Evaluator.readParseAudacitySegments(arena_alloc, ref_path, Evaluator.SpeechSegment.Side.ref);

    var data_logger_conn: ?*DataLogger.Conn = null;
    if (opts.data_logger) |*dl| {
        data_logger_conn = try dl.connect();
        try data_logger_conn.?.initStreamInfo(.{
            .name = name,
            .sample_rate = audio_stream.sample_rate,
        });
        try data_logger_conn.?.insertRefSegments(ref_segments);
    }

    return Self{
        .name = name,
        .audio_stream = audio_stream,
        .reference_segments = ref_segments,
        .data_logger_conn = data_logger_conn,
        .opts = opts,
        .main_thread_allocator = arena_alloc,
        .thread_gpa = .{},
    };
}

pub fn deinit(self: *@This()) void {
    if (self.data_logger_conn) |dl| dl.deinit();
    if (self.eval_result) |*er| er.deinit();
    self.audio_stream.close();
}

/// Thread entry-point for sim instance
pub fn run(self: *Self) !void {
    defer {
        if (builtin.mode != .Debug) _ = self.thread_gpa.detectLeaks();
        _ = self.thread_gpa.deinit();
    }

    var instance_alloc = self.thread_gpa.allocator();

    const vad_segments = try self.simulateVAD();
    defer instance_alloc.free(vad_segments);

    try self.storeResult(vad_segments);
}

fn simulateVAD(self: *Self) ![]AudioPipeline.SpeechSegment {
    log.info(
        "{s}: Streaming {d:.2}s from audio file. Running...",
        .{ self.name, self.audio_stream.durationSeconds() },
    );

    const stream = self.audio_stream;
    const instance_alloc = self.thread_gpa.allocator();

    var pipeline_ctx = PipelineContext{
        .allocator = instance_alloc,
        .sim_instance = self,
    };

    const pipeline = try AudioPipeline.init(
        instance_alloc,
        .{
            .sample_rate = stream.sample_rate,
            .n_channels = stream.n_channels,
            .vad_config = self.opts.sim_config.vad_config,
            .pre_vad_config = self.opts.sim_config.pre_vad_config,
            .record = self.opts.cli_args.record,
            .data_logger = self.data_logger_conn,
        },
        pipeline_ctx.toPipelineCallbacks(),
    );
    defer pipeline.deinit();

    // Run simulation
    {
        // Read 1 second at a time
        const frame_size = 48_000;

        // The backing slice of slices for our audio samples
        var backing_channel_pcm = try instance_alloc.alloc([]f32, stream.n_channels);
        // The slice we'll pass to the audio pipeline, trimmed to the actual number of samples read.
        var trimmed_channel_pcm = try instance_alloc.alloc([]f32, stream.n_channels);
        var channels_allocated: usize = 0;
        defer {
            for (0..channels_allocated) |i| instance_alloc.free(backing_channel_pcm[i]);
            instance_alloc.free(backing_channel_pcm);
            instance_alloc.free(trimmed_channel_pcm);
        }
        // Initialize the backing channel slices
        for (0..backing_channel_pcm.len) |i| {
            backing_channel_pcm[i] = try instance_alloc.alloc(f32, frame_size);
            channels_allocated += 1;
        }

        // Read frames and pass them to the AudioPipeline
        while (true) {
            const frames_read = try stream.read(backing_channel_pcm, 0, frame_size);
            if (frames_read == 0) break;

            for (0..stream.n_channels) |i| {
                trimmed_channel_pcm[i] = backing_channel_pcm[i][0..frames_read];
            }

            _ = try pipeline.pushSamples(trimmed_channel_pcm);
        }
    }

    // Gather VAD segments
    const vad_segments = try pipeline.vad_machine.vad_segments.toOwnedSlice();
    errdefer instance_alloc.free(vad_segments);

    if (self.data_logger_conn) |conn| {
        try conn.insertDetectedSegments(vad_segments);
    }

    return vad_segments;
}

pub fn storeResult(
    self: *Self,
    vad_segments: []AudioPipeline.SpeechSegment,
) !void {
    var speech_segments = try self.main_thread_allocator.alloc(Evaluator.SpeechSegment, vad_segments.len);

    const sample_rate = self.audio_stream.sample_rate;

    for (vad_segments, 0..) |vad_segment, i| {
        speech_segments[i] = Evaluator.SpeechSegment{
            .side = .vad,
            .from_sec = audio_utils.samplesToSeconds(vad_segment.sample_from, sample_rate),
            .to_sec = audio_utils.samplesToSeconds(vad_segment.sample_to, sample_rate),
            .debug_info = null,
        };
    }

    self.eval_result = try Evaluator.evaluate(
        self.main_thread_allocator,
        self.opts.stat_config,
        speech_segments,
        self.reference_segments,
    );
    self.eval_result.?.name = self.name;
}

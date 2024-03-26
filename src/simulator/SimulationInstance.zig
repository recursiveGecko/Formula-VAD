const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
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
    base_path: []const u8,
    output_dir: ?[]const u8,
    instance_json: SimulationInstanceJSON,
    sim_config: DynamicSimConfig,
    cli_args: simulator.CLIArgs,
    data_logger: ?DataLogger,
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

        if (self.sim_instance.output_dir == null) return;

        const audio_file_name = std.fmt.allocPrint(
            allocator,
            "{d}-{s}.ogg",
            .{ audio_buffer.first_sample_number.?, recorder_name },
        ) catch |err| {
            log.err("Failed to allocate file name: {any}", .{err});
            return;
        };
        defer allocator.free(audio_file_name);

        const audio_path = fs.path.resolve(allocator, &.{ self.sim_instance.output_dir.?, audio_file_name }) catch |err| {
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
output_dir: ?[]const u8,
reference_segments: []const Evaluator.SpeechSegment,
evaluator: ?Evaluator = null,
sim_config: DynamicSimConfig,
cli_args: simulator.CLIArgs,
main_thread_allocator: Allocator,

pub fn init(
    arena_alloc: Allocator,
    opts: Opts,
) !Self {
    const name = try arena_alloc.dupe(u8, opts.instance_json.name);

    const audio_path = try fs.path.resolve(arena_alloc, &.{ opts.base_path, opts.instance_json.audio_path });
    const ref_path = try fs.path.resolve(arena_alloc, &.{ opts.base_path, opts.instance_json.ref_path });

    const audio_stream = try AudioFileStream.open(arena_alloc, audio_path);
    const ref_segments = try Evaluator.readParseAudacitySegments(arena_alloc, ref_path, Evaluator.SpeechSegment.Side.ref);

    return Self{
        .name = name,
        .output_dir = opts.output_dir,
        .audio_stream = audio_stream,
        .reference_segments = ref_segments,
        .evaluator = null,
        .sim_config = opts.sim_config,
        .cli_args = opts.cli_args,
        .main_thread_allocator = arena_alloc,
    };
}

pub fn deinit(self: *@This()) void {
    self.audio_stream.close();
}

pub fn run(self: *Self) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = static_sim_config.verbose_allocation_log,
        .thread_safe = false,
    }){};
    defer {
        if (builtin.mode != .Debug) _ = gpa.detectLeaks();
        _ = gpa.deinit();
    }

    var thread_allocator = gpa.allocator();

    log.info(
        "{s}: Streaming {d:.2}s from audio file. Running...",
        .{ self.name, self.audio_stream.durationSeconds() },
    );
    const vad_segments = try self.simulateVAD(thread_allocator, self.audio_stream);
    defer thread_allocator.free(vad_segments);

    try self.storeResult(vad_segments);
}

fn simulateVAD(self: *Self, thread_alloc: Allocator, stream: AudioFileStream) ![]AudioPipeline.SpeechSegment {
    var pipeline_ctx = PipelineContext{
        .allocator = thread_alloc,
        .sim_instance = self,
    };

    const pipeline = try AudioPipeline.init(
        thread_alloc,
        .{
            .sample_rate = stream.sample_rate,
            .n_channels = stream.n_channels,
            .vad_config = self.sim_config.vad_config,
            .record = self.cli_args.record,
        },
        pipeline_ctx.toPipelineCallbacks(),
    );
    defer pipeline.deinit();

    // Run simulation
    {
        const frame_count = self.sim_config.audio_read_frame_count;

        // The backing slice of slices for our audio samples
        var backing_channel_pcm = try thread_alloc.alloc([]f32, stream.n_channels);
        // The slice we'll pass to the audio pipeline, trimmed to the actual number of samples read.
        var trimmed_channel_pcm = try thread_alloc.alloc([]f32, stream.n_channels);
        var channels_allocated: usize = 0;
        defer {
            for (0..channels_allocated) |i| thread_alloc.free(backing_channel_pcm[i]);
            thread_alloc.free(backing_channel_pcm);
            thread_alloc.free(trimmed_channel_pcm);
        }
        // Initialize the backing channel slices
        for (0..backing_channel_pcm.len) |i| {
            backing_channel_pcm[i] = try thread_alloc.alloc(f32, frame_count);
            channels_allocated += 1;
        }

        // Read frames and pass them to the AudioPipeline
        while (true) {
            const frames_read = try stream.read(backing_channel_pcm, 0, frame_count);
            if (frames_read == 0) break;

            for (0..stream.n_channels) |i| {
                trimmed_channel_pcm[i] = backing_channel_pcm[i][0..frames_read];
            }

            _ = try pipeline.pushSamples(trimmed_channel_pcm);
        }
    }

    const vad_segments = try pipeline.vad_machine.vad_segments.toOwnedSlice();
    errdefer thread_alloc.free(vad_segments);

    return vad_segments;
}

pub fn storeResult(
    self: *Self,
    vad_segments: []AudioPipeline.SpeechSegment,
) !void {
    var speech_segments = try self.main_thread_allocator.alloc(Evaluator.SpeechSegment, vad_segments.len);

    const sample_rate = self.audio_stream.sample_rate;

    for (vad_segments, 0..) |vad_segment, i| {
        const from_sec = @as(f32, @floatFromInt(vad_segment.sample_from)) / @as(f32, @floatFromInt(sample_rate));
        const to_sec = @as(f32, @floatFromInt(vad_segment.sample_to)) / @as(f32, @floatFromInt(sample_rate));

        // const debug_info = try std.fmt.allocPrint(
        //     self.main_thread_allocator,
        //     "vr:{d:.2} vad:{d:.1}s",
        //     .{ vad_segment.avg_channel_vol_ratio, vad_segment.vad_met_sec },
        // );

        speech_segments[i] = .{
            .side = .vad,
            .from_sec = from_sec,
            .to_sec = to_sec,
            .debug_info = null,
        };
    }

    self.evaluator = try Evaluator.initAndRun(self.main_thread_allocator, speech_segments, self.reference_segments);
}

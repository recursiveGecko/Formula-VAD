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
};

// Wraps the pipeline context that is required for AudioPipeline callbacks
const PipelineContext = struct {
    sim_instance: *SimulationInstance,

    pub fn onRecording(
        self_opaque: *anyopaque,
        recorder_name: []const u8,
        audio_buffer: AudioBuffer,
    ) void {
        const self: *PipelineContext = @ptrCast(@alignCast(self_opaque));
        const allocator = self.sim_instance.main_thread_allocator;

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
audio_source: *AudioSource,
output_dir: ?[]const u8,
reference_segments: []const Evaluator.SpeechSegment,
evaluator: ?Evaluator = null,
sim_config: DynamicSimConfig,
main_thread_allocator: Allocator,
cli_args: simulator.CLIArgs,

pub fn init(
    allocator: Allocator,
    opts: Opts,
) !Self {
    const name = try allocator.dupe(u8, opts.instance_json.name);
    errdefer allocator.free(name);

    const audio_path = try fs.path.resolve(allocator, &.{ opts.base_path, opts.instance_json.audio_path });
    defer allocator.free(audio_path);

    const ref_path = try fs.path.resolve(allocator, &.{ opts.base_path, opts.instance_json.ref_path });
    defer allocator.free(ref_path);

    const audio_source = try allocator.create(AudioSource);
    errdefer allocator.destroy(audio_source);

    if (opts.sim_config.preload_audio) {
        const audio_buffer = try AudioBuffer.loadFromFile(allocator, audio_path);
        audio_source.* = AudioSource{ .buffer = audio_buffer };
    } else {
        const audio_stream = try AudioFileStream.open(allocator, audio_path);
        audio_source.* = AudioSource{ .stream = audio_stream };
    }

    const ref_segments = try Evaluator.readParseAudacitySegments(allocator, ref_path, Evaluator.SpeechSegment.Side.ref);
    errdefer allocator.free(ref_segments);

    return Self{
        .name = name,
        .output_dir = opts.output_dir,
        .audio_source = audio_source,
        .reference_segments = ref_segments,
        .evaluator = null,
        .main_thread_allocator = allocator,
        .sim_config = opts.sim_config,
        .cli_args = opts.cli_args,
    };
}

pub fn deinit(self: *@This()) void {
    const alloc = self.main_thread_allocator;

    self.audio_source.deinit();
    alloc.destroy(self.audio_source);
    alloc.free(self.name);
    alloc.free(self.reference_segments);
    if (self.output_dir) |od| alloc.free(od);
    if (self.evaluator) |*e| e.deinit();
}

pub fn run(self: *Self) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = static_sim_config.verbose_allocation_log,
    }){};
    defer {
        if (builtin.mode != .Debug) _ = gpa.detectLeaks();
        _ = gpa.deinit();
    }

    var thread_allocator = gpa.allocator();

    log.info(
        "{s}: Streaming {d:.2}s from audio file. Running...",
        .{ self.name, self.audio_source.durationSeconds() },
    );
    const vad_segments = try self.simulateVAD(thread_allocator, self.audio_source);
    defer thread_allocator.free(vad_segments);

    try self.storeResult(vad_segments);
}

fn simulateVAD(self: *Self, allocator: Allocator, audio: *AudioSource) ![]AudioPipeline.SpeechSegment {
    var pipeline_ctx = PipelineContext{
        .sim_instance = self,
    };

    const pipeline = try AudioPipeline.init(
        allocator,
        .{
            .sample_rate = audio.sampleRate(),
            .n_channels = audio.nChannels(),
            .vad_config = self.sim_config.vad_config,
            .record = self.cli_args.record,
            // .skip_processing = true,
        },
        pipeline_ctx.toPipelineCallbacks(),
    );
    defer pipeline.deinit();

    // const sample_rate = audio.sampleRate();

    if (audio.* == .stream) {
        var stream = audio.stream;
        const frame_count = self.sim_config.audio_read_frame_count;

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
            backing_channel_pcm[i] = try allocator.alloc(f32, frame_count);
            channels_allocated += 1;
        }

        // Read frames and pass them to the AudioPipeline
        while (true) {
            const frames_read = try stream.read(backing_channel_pcm, 0, frame_count);
            if (frames_read == 0) break;

            for (0..audio.nChannels()) |i| {
                trimmed_channel_pcm[i] = backing_channel_pcm[i][0..frames_read];
            }

            _ = try pipeline.pushSamples(trimmed_channel_pcm);
        }
    } else if (audio.* == .buffer) {
        const audio_buffer = audio.buffer;
        _ = try pipeline.pushSamples(audio_buffer.channel_pcm_buf);
    } else {
        unreachable;
    }

    const vad_segments = try pipeline.vad_machine.vad_segments.toOwnedSlice();
    errdefer allocator.free(vad_segments);

    return vad_segments;
}

pub fn storeResult(
    self: *Self,
    vad_segments: []AudioPipeline.SpeechSegment,
) !void {
    var speech_segments = try self.main_thread_allocator.alloc(Evaluator.SpeechSegment, vad_segments.len);
    errdefer self.main_thread_allocator.free(speech_segments);

    const sample_rate = self.audio_source.sampleRate();

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
    errdefer self.evaluator.deinit();
}

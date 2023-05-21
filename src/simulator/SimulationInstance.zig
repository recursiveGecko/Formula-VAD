const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AudioPipeline = @import("../AudioPipeline.zig");
const AudioFileStream = @import("../audio_utils/AudioFileStream.zig");
const AudioBuffer = @import("../audio_utils/AudioBuffer.zig");
const AudioSource = @import("../audio_utils/AudioSource.zig").AudioSource;
const VAD = @import("../AudioPipeline/VAD.zig");
const simulator = @import("../simulator.zig");
const Evaluator = @import("../Evaluator.zig");
const static_sim_config = simulator.static_sim_config;
const SimulationInstanceJSON = simulator.SimulationInstanceJSON;
const DynamicSimConfig = simulator.DynamicSimConfig;
const log = std.log.scoped(.sim_instance);
const fs = std.fs;

const Self = @This();

name: []const u8,
audio_source: *AudioSource,
output_dir: []const u8,
reference_segments: []const Evaluator.SpeechSegment,
evaluator: ?Evaluator = null,
sim_config: DynamicSimConfig,
main_thread_allocator: Allocator,

pub fn init(
    allocator: Allocator,
    base_path: []const u8,
    instance_json: SimulationInstanceJSON,
    sim_config: DynamicSimConfig,
) !Self {
    const name = try allocator.dupeZ(u8, instance_json.name);
    errdefer allocator.free(name);

    const audio_path = try fs.path.resolve(allocator, &.{ base_path, instance_json.audio_path });
    defer allocator.free(audio_path);

    const ref_path = try fs.path.resolve(allocator, &.{ base_path, instance_json.ref_path });
    defer allocator.free(ref_path);

    var audio_source = try allocator.create(AudioSource);
    errdefer allocator.destroy(audio_source);

    if (sim_config.preload_audio) {
        const audio_buffer = try AudioBuffer.loadFromFile(allocator, audio_path);
        audio_source.* = AudioSource{ .buffer = audio_buffer };
    } else {
        const audio_stream = try AudioFileStream.open(allocator, audio_path);
        audio_source.* = AudioSource{ .stream = audio_stream };
    }

    const ref_segments = try Evaluator.readParseAudacitySegments(allocator, ref_path);
    errdefer allocator.free(ref_segments);

    return Self{
        .name = name,
        .output_dir = "",
        .audio_source = audio_source,
        .reference_segments = ref_segments,
        .evaluator = null,
        .main_thread_allocator = allocator,
        .sim_config = sim_config,
    };
}

pub fn deinit(self: *@This()) void {
    const alloc = self.main_thread_allocator;

    self.audio_source.deinit();
    alloc.destroy(self.audio_source);
    alloc.free(self.name);
    alloc.free(self.output_dir);
    alloc.free(self.reference_segments);
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
    var vad_segments = try self.simulateVAD(thread_allocator, self.audio_source);
    defer thread_allocator.free(vad_segments);

    try self.storeResult(vad_segments);
}

fn simulateVAD(self: *Self, allocator: Allocator, audio: *AudioSource) ![]VAD.VADSegment {
    const pipeline = try AudioPipeline.init(allocator, .{
        .sample_rate = audio.sampleRate(),
        .n_channels = audio.nChannels(),
        .vad_config = self.sim_config.vad_config,
        // .skip_processing = true,
    });
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
    self: *Self,
    vad_segments: []VAD.VADSegment,
) !void {
    var speech_segments = try self.main_thread_allocator.alloc(Evaluator.SpeechSegment, vad_segments.len);
    errdefer self.main_thread_allocator.free(speech_segments);

    const sample_rate = self.audio_source.sampleRate();

    for (vad_segments, 0..) |vad_segment, i| {
        const from_sec = @intToFloat(f32, vad_segment.sample_from) / @intToFloat(f32, sample_rate);
        const to_sec = @intToFloat(f32, vad_segment.sample_to) / @intToFloat(f32, sample_rate);

        const debug_info = try std.fmt.allocPrint(
            self.main_thread_allocator,
            "rnn:{d:.2}% vr:{d:.2}",
            .{ vad_segment.debug_rnn_vad * 100, vad_segment.debug_avg_speech_vol_ratio },
        );

        speech_segments[i] = .{
            .from_sec = from_sec,
            .to_sec = to_sec,
            .debug_info = debug_info,
        };
    }

    self.evaluator = try Evaluator.initAndRun(self.main_thread_allocator, speech_segments, self.reference_segments);
    errdefer self.evaluator.deinit();
}

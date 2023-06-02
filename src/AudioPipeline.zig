const std = @import("std");
const log = std.log.scoped(.pipeline);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Segment = @import("./AudioPipeline/Segment.zig");
const MRBRecorder = @import("./AudioPipeline/MRBRecorder.zig");
const SplitSlice = @import("./structures/SplitSlice.zig").SplitSlice;
const MultiRingBuffer = @import("./structures/MultiRingBuffer.zig").MultiRingBuffer;
pub const VAD = @import("./AudioPipeline/VAD.zig");
pub const AudioBuffer = @import("./audio_utils/AudioBuffer.zig");

const Self = @This();

pub const Callbacks = struct {
    ctx: *anyopaque,
    on_original_recording: ?*const fn (ctx: *anyopaque, recording: *const AudioBuffer) void,
    on_denoised_recording: ?*const fn (ctx: *anyopaque, recording: *const AudioBuffer) void,
};

pub const Config = struct {
    sample_rate: usize,
    n_channels: usize,
    buffer_length: ?usize = null,
    vad_config: VAD.Config = .{},
    skip_processing: bool = false,
};

allocator: Allocator,
config: Config,
original_audio_buffer: MultiRingBuffer(f32, u64),
denoised_audio_buffer: MultiRingBuffer(f32, u64),
original_audio_recorder: MRBRecorder,
denoised_audio_recorder: MRBRecorder,
vad: VAD,
callbacks: ?Callbacks = null,
// Temporarily holds a slice of channel data, e.g. when writing
// denoised Segments to the denoised_audio_buffer
temp_channel_slice: [][]const f32,

pub fn init(
    allocator: Allocator,
    config: Config,
    callbacks: ?Callbacks,
) !*Self {
    // TODO: Calculate a more optional length?
    const buffer_length = config.buffer_length orelse config.sample_rate * 10;

    var original_audio_buffer = try MultiRingBuffer(f32, u64).init(
        allocator,
        config.n_channels,
        buffer_length,
    );
    errdefer original_audio_buffer.deinit();

    var denoised_audio_buffer = try MultiRingBuffer(f32, u64).init(
        allocator,
        config.n_channels,
        buffer_length,
    );
    errdefer denoised_audio_buffer.deinit();

    var temp_channel_slice = try allocator.alloc([]const f32, config.n_channels);
    errdefer allocator.free(temp_channel_slice);

    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = Self{
        .config = config,
        .allocator = allocator,
        .original_audio_buffer = original_audio_buffer,
        .denoised_audio_buffer = denoised_audio_buffer,
        .original_audio_recorder = undefined,
        .denoised_audio_recorder = undefined,
        .vad = undefined,
        .callbacks = callbacks,
        .temp_channel_slice = temp_channel_slice,
    };

    self.vad = try VAD.init(self, config.vad_config);
    errdefer self.vad.deinit();

    self.original_audio_recorder = try MRBRecorder.init(
        allocator,
        &self.original_audio_buffer,
        config.sample_rate,
        @ptrCast(*const MRBRecorder.RecordingCB, &onOriginalRecording),
        self,
    );
    errdefer self.original_audio_recorder.deinit();

    self.denoised_audio_recorder = try MRBRecorder.init(
        allocator,
        &self.denoised_audio_buffer,
        config.sample_rate,
        @ptrCast(*const MRBRecorder.RecordingCB, &onDenoisedRecording),
        self,
    );
    errdefer self.denoised_audio_recorder.deinit();

    return self;
}

pub fn deinit(self: *Self) void {
    self.vad.deinit();
    self.original_audio_buffer.deinit();
    self.original_audio_recorder.deinit();
    self.denoised_audio_buffer.deinit();
    self.denoised_audio_recorder.deinit();
    self.allocator.free(self.temp_channel_slice);
    self.allocator.destroy(self);
}

pub fn totalWriteCount(self: *const Self) u64 {
    return self.original_audio_buffer.total_write_count;
}

pub fn pushSamples(self: *Self, channel_pcm: []const []const f32) !u64 {
    const first_sample_index = self.original_audio_buffer.total_write_count;

    const n_samples = channel_pcm[0].len;
    // Write in chunks of `write_chunk_size` samples to ensure we don't
    // write too much data before processing it
    const write_chunk_size = self.original_audio_buffer.capacity / 2;
    var read_offset: usize = 0;
    while (true) {
        // We record as many samples as we're going to write
        const n_written_this_step = @min(write_chunk_size, n_samples - read_offset);
        try self.original_audio_recorder.recordBeforeMRBWrite(n_written_this_step);

        const n_written = self.original_audio_buffer.writeAssumeCapacity(
            channel_pcm,
            read_offset,
            write_chunk_size,
        );
        read_offset += n_written;

        try self.maybeRunPipeline();
        if (n_written < write_chunk_size) break;
    }

    return first_sample_index;
}

pub fn pushDenoisedSamples(self: *Self, denoised_segment: *const Segment) !void {
    const n_written_this_step = denoised_segment.length;

    try self.denoised_audio_recorder.recordBeforeMRBWrite(n_written_this_step);

    const split_slices = denoised_segment.channel_pcm_buf;
    for (split_slices, 0..) |split_channel, i_channel| {
        self.temp_channel_slice[i_channel] = split_channel.first;
        assert(split_channel.second.len == 0);
    }

    const n_written = self.denoised_audio_buffer.write(
        self.temp_channel_slice,
        0,
        n_written_this_step,
    );

    // This should never happen, our buffer should be many orders of magnitude
    // larger than the segment we're writing
    if (n_written != n_written_this_step) {
        @panic("Failed to write denoised samples to denoised audio buffer");
    }
}

/// Slice samples using absolute indices, from `abs_from` inclusive to `abs_to` exclusive.
pub fn sliceSegment(self: Self, result_segment: *Segment, abs_from: u64, abs_to: u64) !void {
    try self.original_audio_buffer.readSlice(
        result_segment.channel_pcm_buf,
        abs_from,
        abs_to,
    );

    result_segment.*.index = abs_from;
    result_segment.*.length = abs_to - abs_from;
}

pub fn startRecording(self: *Self, from_sample: usize) !void {
    try self.original_audio_recorder.startRecording(from_sample);
    try self.denoised_audio_recorder.startRecording(from_sample);
}

pub fn endRecording(self: *Self, to_sample: usize, keep: bool) !void {
    try self.original_audio_recorder.stopRecording(to_sample, keep);
    try self.denoised_audio_recorder.stopRecording(to_sample, keep);
}

pub fn onOriginalRecording(self: *Self, audio_buffer: *AudioBuffer) void {
    defer audio_buffer.deinit();
    const cb_config = self.callbacks orelse return;

    if (cb_config.on_original_recording) |cb| {
        cb(cb_config.ctx, audio_buffer);
    }
}

pub fn onDenoisedRecording(self: *Self, audio_buffer: *AudioBuffer) void {
    defer audio_buffer.deinit();
    const cb_config = self.callbacks orelse return;

    if (cb_config.on_denoised_recording) |cb| {
        cb(cb_config.ctx, audio_buffer);
    }
}

fn maybeRunPipeline(self: *Self) !void {
    if (self.config.skip_processing) return;
    try self.vad.run();
}

//
// Tests
//

test {
    _ = @import("./AudioPipeline/SegmentWriter.zig");
}

test "simple leak test" {
    var pipeline = try init(
        std.testing.allocator,
        .{
            .n_channels = 2,
            .sample_rate = 48000,
            .vad_config = .{
                .alt_vad_machine_configs = &.{
                    .{},
                    .{},
                },
            },
        },
        null,
    );
    defer pipeline.deinit();
}

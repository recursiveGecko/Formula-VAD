const std = @import("std");
const log = std.log.scoped(.pipeline);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Segment = @import("./AudioPipeline/Segment.zig");
const MRBRecorder = @import("./AudioPipeline/MRBRecorder.zig");
const AudioMRB = @import("./types.zig").AudioMRB;
const VADPipeline = @import("./AudioPipeline/VADPipeline.zig");
const AudioBuffer = @import("./audio_utils/AudioBuffer.zig");

const Self = @This();

pub const Callbacks = struct {
    ctx: *anyopaque,
    on_recording: ?*const fn (ctx: *anyopaque, recording: *const AudioBuffer) void,
};

pub const Config = struct {
    sample_rate: usize,
    n_channels: usize,
    buffer_length: ?usize = null,
    vad_config: VADPipeline.Config = .{},
    skip_processing: bool = false,
};

allocator: Allocator,
config: Config,
ring_buffer: AudioMRB,
recorder: MRBRecorder,
vad: VADPipeline,
callbacks: ?Callbacks = null,

pub fn init(
    allocator: Allocator,
    config: Config,
    callbacks: ?Callbacks,
) !*Self {
    const buffer_length = config.buffer_length orelse config.sample_rate * 5;

    var ring_buffer = try AudioMRB.init(
        allocator,
        config.n_channels,
        buffer_length,
    );
    errdefer ring_buffer.deinit();

    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = Self{
        .config = config,
        .allocator = allocator,
        .ring_buffer = ring_buffer,
        .recorder = undefined,
        .vad = undefined,
        .callbacks = callbacks,
    };

    self.vad = try VADPipeline.init(self, config.vad_config);
    errdefer self.vad.deinit();

    self.recorder = try MRBRecorder.init(
        allocator,
        &self.ring_buffer,
        config.sample_rate,
        @ptrCast(&onRecording),
        self,
    );
    errdefer self.recorder.deinit();

    return self;
}

pub fn deinit(self: *Self) void {
    self.vad.deinit();
    self.ring_buffer.deinit();
    self.recorder.deinit();
    self.allocator.destroy(self);
}

pub fn totalWriteCount(self: *const Self) u64 {
    return self.ring_buffer.total_write_count;
}

pub fn pushSamples(self: *Self, channel_pcm: []const []const f32) !u64 {
    const first_sample_index = self.ring_buffer.total_write_count;

    const n_total_samples = channel_pcm[0].len;
    const n_samples_one_second = self.config.sample_rate;

    var read_offset: usize = 0;
    while (true) {
        // We record as many samples as we're going to write
        const max_written_this_step = @min(n_samples_one_second, n_total_samples - read_offset);
        const expected_write_index = self.totalWriteCount() + max_written_this_step;

        try self.recorder.beforePipelineWrite(expected_write_index);

        const n_written = self.ring_buffer.writeAssumeCapacity(
            channel_pcm,
            read_offset,
            // Write at most 1 second per step
            max_written_this_step,
        );
        read_offset += n_written;

        try self.maybeRunPipeline();
        if (read_offset == n_total_samples) break;
        if (read_offset > n_total_samples) @panic("impossible counter - pushSamples()");
    }

    return first_sample_index;
}

/// Slice samples using absolute indices, from `abs_from` inclusive to `abs_to` exclusive.
pub fn readRingBuffer(self: *Self, abs_from: u64, abs_to: u64) !AudioMRB.SplitSlice {
    return try self.ring_buffer.sliceBuffer(
        abs_from,
        abs_to,
    );
}

pub fn startRecording(self: *Self, from_sample: usize) !void {
    log.info("Starting original & denoised recording from sample {d}", .{from_sample});
    try self.recorder.startRecording(from_sample);
}

pub fn endRecording(self: *Self, to_sample: usize, keep: bool) !void {
    log.info("Ending recording at sample {d}, keep: {}", .{ to_sample, keep });
    try self.recorder.stopRecording(to_sample, keep);
}

pub fn onRecording(self: *Self, audio_buffer: *AudioBuffer) void {
    defer audio_buffer.deinit();
    const cb_config = self.callbacks orelse return;

    if (cb_config.on_recording) |cb| {
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

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
    on_recording: ?*const fn (ctx: *anyopaque, recording: *const AudioBuffer) void,
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
multi_ring_buffer: MultiRingBuffer(f32, u64),
mrb_recorder: MRBRecorder,
vad: VAD,
callbacks: ?Callbacks = null,

pub fn init(
    allocator: Allocator,
    config: Config,
    callbacks: ?Callbacks,
) !*Self {
    // TODO: Calculate a more optional length?
    const buffer_length = config.buffer_length orelse config.sample_rate * 10;

    var multi_ring_buffer = try MultiRingBuffer(f32, u64).init(
        allocator,
        config.n_channels,
        buffer_length,
    );
    errdefer multi_ring_buffer.deinit();

    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = Self{
        .config = config,
        .allocator = allocator,
        .multi_ring_buffer = multi_ring_buffer,
        .callbacks = callbacks,
        .vad = undefined,
        .mrb_recorder = undefined,
    };

    self.vad = try VAD.init(self, config.vad_config);
    errdefer self.vad.deinit();

    self.mrb_recorder = try MRBRecorder.init(
        allocator,
        &self.multi_ring_buffer,
        config.sample_rate,
        @ptrCast(*const MRBRecorder.RecordingCB, &onRecording),
        self,
    );
    errdefer self.mrb_recorder.deinit();

    return self;
}

pub fn deinit(self: *Self) void {
    self.vad.deinit();
    self.multi_ring_buffer.deinit();
    self.mrb_recorder.deinit();
    self.allocator.destroy(self);
}

pub fn pushSamples(self: *Self, channel_pcm: []const []const f32) !u64 {
    const first_sample_index = self.multi_ring_buffer.total_write_count;

    const n_samples = channel_pcm[0].len;
    // Write in chunks of `write_chunk_size` samples to ensure we don't
    // write too much data before processing it
    const write_chunk_size = self.multi_ring_buffer.capacity / 2;
    var read_offset: usize = 0;
    while (true) {
        // We record as many samples as we're going to write
        const n_written_this_step = @min(write_chunk_size, n_samples - read_offset);
        try self.mrb_recorder.recordBeforeMRBWrite(n_written_this_step);

        const n_written = self.multi_ring_buffer.writeAssumeCapacity(
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

/// Slice samples using absolute indices, from `abs_from` inclusive to `abs_to` exclusive.
pub fn sliceSegment(self: Self, result_segment: *Segment, abs_from: u64, abs_to: u64) !void {
    try self.multi_ring_buffer.readSlice(
        result_segment.channel_pcm_buf,
        abs_from,
        abs_to,
    );

    result_segment.*.index = abs_from;
    result_segment.*.length = abs_to - abs_from;
}

pub fn startRecording(self: *Self, from_sample: usize) !void {
    try self.mrb_recorder.startRecording(from_sample);
}

pub fn endRecording(self: *Self, to_sample: usize, keep: bool) !void {
    try self.mrb_recorder.stopRecording(to_sample, keep);
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

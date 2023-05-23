const std = @import("std");
const log = std.log.scoped(.pipeline);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const PipelineFFT = @import("./AudioPipeline/PipelineFFT.zig");
const Segment = @import("./AudioPipeline/Segment.zig");
const VAD = @import("./AudioPipeline/VAD.zig");
const SplitSlice = @import("./structures/SplitSlice.zig").SplitSlice;
const MultiRingBuffer = @import("./structures/MultiRingBuffer.zig").MultiRingBuffer;
const Self = @This();

pub const Config = struct {
    sample_rate: usize,
    n_channels: usize,
    buffer_length: ?usize = null,
    vad_config: VAD.Config = .{},
    skip_processing: bool = false,
};

allocator: Allocator,
config: Config,
multi_ring_buffer: MultiRingBuffer(f32, u64) = undefined,
vad: VAD = undefined,

pub fn init(allocator: Allocator, config: Config) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = std.mem.zeroInit(Self, .{
        .config = config,
        .allocator = allocator,
    });

    // TODO: Calculate a more optional length?
    const buffer_length = config.buffer_length orelse config.sample_rate * 10;

    self.multi_ring_buffer = try MultiRingBuffer(f32, u64).init(
        allocator,
        config.n_channels,
        buffer_length,
    );
    errdefer self.multi_ring_buffer.deinit();

    self.vad = try VAD.init(self, config.vad_config);
    errdefer self.vad.deinit();

    return self;
}

pub fn deinit(self: *Self) void {
    self.vad.deinit();
    self.multi_ring_buffer.deinit();
    self.allocator.destroy(self);
}

pub fn pushSamples(self: *Self, channel_pcm: []const []const f32) !void {
    // Write in chunks of `write_chunk_size` samples to ensure we don't
    // write too much data before processing it
    const write_chunk_size = self.multi_ring_buffer.capacity / 2;
    var read_offset: usize = 0;
    while (true) {
        const n_written = self.multi_ring_buffer.writeAssumeCapacity(
            channel_pcm,
            read_offset,
            write_chunk_size,
        );
        read_offset += n_written;

        try self.runPipeline();
        if (n_written < write_chunk_size) break;
    }
}

pub fn runPipeline(self: *Self) !void {
    if (self.config.skip_processing) return;

    try self.vad.run();
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

pub fn beginCapture(self: *Self, from_sample: usize) !void {
    _ = from_sample;
    _ = self;
}

pub fn endCapture(self: *Self, to_sample: usize, keep: bool) !void {
    _ = keep;
    _ = to_sample;
    _ = self;
}

pub fn durationToSamples(sample_rate: usize, buffer_duration: f32) usize {
    const duration_f = (@intToFloat(f32, sample_rate) * buffer_duration);
    return @floatToInt(usize, @ceil(duration_f));
}

//
// Tests
//

test {
    _ = @import("./AudioPipeline/SegmentWriter.zig");
}

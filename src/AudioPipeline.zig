const std = @import("std");
const log = std.log.scoped(.pipeline);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const PipelineFFT = @import("./AudioPipeline/PipelineFFT.zig");
const Segment = @import("./AudioPipeline/Segment.zig");
const VAD = @import("./AudioPipeline/VAD.zig");
const SplitSlice = @import("./structures/SplitSlice.zig").SplitSlice;
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
raw_pcm_buf: ?[]f32 = null,
channel_pcm_buf: ?[][]f32 = null,
buffer_length: usize,
total_write_count: u64 = 0,
vad: ?VAD = null,

pub fn init(allocator: Allocator, config: Config) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = std.mem.zeroInit(Self, .{
        .config = config,
        .allocator = allocator,
        .buffer_length = undefined,
    });

    // TODO: Calculate a more optional length?
    self.buffer_length = config.buffer_length orelse config.sample_rate * 30;

    self.channel_pcm_buf = try allocator.alloc([]f32, config.n_channels);
    errdefer allocator.free(self.channel_pcm_buf.?);

    self.raw_pcm_buf = try allocator.alloc(f32, config.n_channels * self.buffer_length);
    errdefer allocator.free(self.raw_pcm_buf.?);

    self.vad = try VAD.init(self, config.vad_config);
    errdefer self.vad.deinit();

    for (0..config.n_channels) |idx| {
        const from = idx * self.buffer_length;
        const to = from + self.buffer_length;
        self.channel_pcm_buf.?[idx] = self.raw_pcm_buf.?[from..to];
    }

    self.allocator = allocator;
    self.config = config;

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.vad) |*vad| {
        vad.deinit();
        self.vad = null;
    }

    if (self.channel_pcm_buf) |buf| {
        self.allocator.free(buf);
        self.channel_pcm_buf = null;
    }

    if (self.raw_pcm_buf) |buf| {
        self.allocator.free(buf);
        self.raw_pcm_buf = null;
    }

    self.allocator.destroy(self);
}

pub fn processedCount(self: Self) usize {
    return self.vad.?.fully_processed_count;
}

pub fn pushSamples(self: *Self, channel_pcm: []const []const f32) !void {
    // Assert that we have the same number of channels as configured
    assert(channel_pcm.len == self.config.n_channels);

    const n_total_input_samples = channel_pcm[0].len;

    for (0..self.config.n_channels) |channel_idx| {
        // Assert that all input channels have the same number of samples
        assert(channel_pcm[channel_idx].len == n_total_input_samples);
    }

    // We could add a smarter strategy, by observing `.processedCount()`
    // to know how far we can write, but this is good enough
    const write_chunk_size = self.buffer_length / 2;
    var src_read_offset: usize = 0;

    // Write in chunks of `write_chunk_size` samples to ensure we don't
    // write too much data before processing it
    while (true) {
        const dst_write_index = self.total_write_count % self.buffer_length;
        // Number of samples remaining until we reach the end of the ring buffer
        // and need to start writing from the start again
        const dst_distance_to_end = self.buffer_length - dst_write_index;
        // Number of samples remaining in the input/source buffer
        const src_remaining = n_total_input_samples - src_read_offset;

        // Number of samples to write **in this iteration**
        const n_samples_to_write = @min(src_remaining, write_chunk_size);

        // Step 1. Range of samples to write until the end of the ring buffer
        const to_end__src_from = src_read_offset;
        const to_end__src_to = to_end__src_from + @min(dst_distance_to_end, n_samples_to_write);

        const to_end__dst_from = dst_write_index;
        const to_end__dst_to = to_end__dst_from + @min(dst_distance_to_end, n_samples_to_write);

        const to_end__count = to_end__dst_to - to_end__dst_from;

        // Step 2. Range of samples to write from the start of the ring buffer, usually 0
        const from_start__count = n_samples_to_write - to_end__count;

        const from_start__src_from = src_read_offset + to_end__count;
        const from_start__src_to = from_start__src_from + from_start__count;

        const from_start__dst_from = 0;
        const from_start__dst_to = from_start__count;

        for (0..self.config.n_channels) |channel_idx| {
            var src_channel = channel_pcm[channel_idx];
            var dst_channel = self.channel_pcm_buf.?[channel_idx];

            var src_read_slice = src_channel[to_end__src_from..to_end__src_to];
            var dst_write_slice = dst_channel[to_end__dst_from..to_end__dst_to];
            @memcpy(dst_write_slice, src_read_slice);

            if (from_start__count > 0) {
                src_read_slice = src_channel[from_start__src_from..from_start__src_to];
                dst_write_slice = dst_channel[from_start__dst_from..from_start__dst_to];
                @memcpy(dst_write_slice, src_read_slice);
            }
        }

        self.total_write_count += n_samples_to_write;
        src_read_offset += n_samples_to_write;

        try self.runPipeline();

        if (src_read_offset == n_total_input_samples) break;
    }
}

pub fn runPipeline(self: *Self) !void {
    if (self.config.skip_processing) return;

    try self.vad.?.run();
}

/// Slice samples using absolute indices, from `abs_from` inclusive to `abs_to` exclusive.
pub fn sliceSegment(self: Self, result_segment: *Segment, abs_from: u64, abs_to: u64) !void {
    // Valid slicing range
    const max_abs_idx = self.total_write_count;
    const min_abs_idx = if (max_abs_idx >= self.buffer_length) max_abs_idx - self.buffer_length else 0;

    if (abs_to <= abs_from) {
        return error.InvalidRange;
    }

    if (abs_to - abs_from > self.buffer_length) {
        return error.RangeTooLong;
    }

    if (abs_from < min_abs_idx or abs_to > max_abs_idx) {
        return error.IndexOutOfBounds;
    }

    const rel_from = abs_from % self.buffer_length;
    const rel_to = abs_to % self.buffer_length;

    var first_from: usize = 0;
    var first_to: usize = 0;
    var second_to: usize = 0;

    // If the indices are equal, it means the entire buffer was requested
    if (rel_to <= rel_from) {
        first_from = rel_from;
        first_to = self.buffer_length;
        second_to = rel_to;
    } else {
        first_from = rel_from;
        first_to = rel_to;
    }

    var result_split_slice = result_segment.*.channel_pcm_buf;
    const n_channels = self.config.n_channels;

    for (0..n_channels) |channel_idx| {
        result_split_slice[channel_idx] = SplitSlice(f32){
            .first = self.channel_pcm_buf.?[channel_idx][first_from..first_to],
            .second = self.channel_pcm_buf.?[channel_idx][0..second_to],
        };
    }

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

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const test_allocator = std.testing.allocator;

test "pushSamples() ring buffer handling" {
    var pipeline = try init(test_allocator, .{
        .skip_processing = true,
        .sample_rate = 48000,
        .buffer_length = 5,
        .n_channels = 1,
    });
    defer pipeline.deinit();

    var pcm = pipeline.channel_pcm_buf.?[0];

    try pipeline.pushSamples(&.{&.{ 0, 1, 2 }});
    // write index:          v
    // expected:   [0, 1, 2, _, _]
    try expectEqualSlices(f32, &.{ 0, 1, 2 }, pcm[0..3]);

    try pipeline.pushSamples(&.{&.{ 4, 5, 6, 7, 8, 9 }});
    // write index:             v
    // expected:   [6, 7, 8, 9, 5]
    try expectEqualSlices(f32, &.{ 6, 7, 8, 9, 5 }, pcm);

    try pipeline.pushSamples(&.{&.{ 2, 3, 4 }});
    // write index:       v
    // expected:   [3, 4, 8, 9, 2]
    try expectEqualSlices(f32, &.{ 3, 4, 8, 9, 2 }, pcm);

    try pipeline.pushSamples(&.{&.{ 0, 0, 0, 0, 0, 50, 60, 70, 80, 90 }});
    // write index:         v
    // expected:   [80, 90, 50, 60, 70]
    try expectEqualSlices(f32, &.{ 80, 90, 50, 60, 70 }, pcm);

    try pipeline.pushSamples(&.{&.{ -1, 0, 2, 0 }});
    // write index:    v
    // expected:   [0, 90, -1, 0, 2]
    try expectEqualSlices(f32, &.{ 0, 90, -1, 0, 2 }, pcm);
}

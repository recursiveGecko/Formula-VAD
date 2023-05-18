const std = @import("std");
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

    self.vad = try VAD.init(self, .{});
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

pub fn pushSamples(self: *Self, channel_pcm: []const []const f32) !void {
    // Assert that we have the same number of channels as configured
    assert(channel_pcm.len == self.config.n_channels);

    const n_input_samples = channel_pcm[0].len;
    const sample_write_idx = self.total_write_count % self.buffer_length;

    for (0..self.config.n_channels) |channel_idx| {
        // Assert that all input channels have the same number of samples
        assert(channel_pcm[channel_idx].len == n_input_samples);

        // Step 1: Write up to the end of the buffer
        const rem_to_end = self.buffer_length - sample_write_idx;
        const to_end = @min(n_input_samples, rem_to_end);

        var src_channel = channel_pcm[channel_idx][0..to_end];
        var dst_channel = self.channel_pcm_buf.?[channel_idx][sample_write_idx..];
        // TODO: Zig 0.11.x doesn't support copying shorter slices into longer ones
        dst_channel = dst_channel[0..src_channel.len];
        @memcpy(dst_channel, src_channel);

        // Step 2: Write any remaining samples to the start of the buffer
        const from_start = @max(0, n_input_samples - to_end);

        if (from_start > 0) {
            src_channel = channel_pcm[channel_idx][to_end..];
            dst_channel = self.channel_pcm_buf.?[channel_idx][0..];
            // TODO: Zig 0.11.x doesn't support copying shorter slices into longer ones
            dst_channel = dst_channel[0..src_channel.len];
            @memcpy(dst_channel, src_channel);
        }
    }

    self.total_write_count += n_input_samples;

    try self.runPipeline();
}

pub fn runPipeline(self: *Self) !void {
    try self.vad.?.run();
}

/// Slice samples using absolute indices, from `abs_from` inclusive to `abs_to` exclusive.
pub fn sliceSegment(self: Self, abs_from: u64, abs_to: u64) !Segment {
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

    const channels = try self.allocator.alloc(SplitSlice(f32), self.config.n_channels);
    errdefer self.allocator.free(channels);

    for (0..channels.len) |channel_idx| {
        channels[channel_idx] = SplitSlice(f32){
            .first = self.channel_pcm_buf.?[channel_idx][first_from..first_to],
            .second = self.channel_pcm_buf.?[channel_idx][0..second_to],
        };
    }

    return Segment{
        .index = abs_from,
        .length = abs_to - abs_from,
        .allocator = self.allocator,
        .channel_pcm_buf = channels,
    };
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

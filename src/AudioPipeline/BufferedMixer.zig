/// Downmixes multi-channel audio into single channel by keeping the quieter channel
/// using long-term RMS volume
const std = @import("std");
const log = std.log.scoped(.buffered_mixer);
const BufferedStep = @import("BufferedStep.zig");
const Segment = @import("Segment.zig");
const audio_utils = @import("../audio_utils.zig");
const RollingAverage = @import("../structures/RollingAverage.zig");

const Self = @This();

const max_in_channels = 2;
const left_idx = 0;
const right_idx = 1;

const in_buffer_ms = 100;
const best_channel_rolling_avg_ms = 20_000;
const switch_best_threshold: f32 = 0.1;

allocator: std.mem.Allocator,
out_segment: Segment,
out_result: BufferedStep.Result,
best_channel: usize = 0,
channel_rolling_avgs: []RollingAverage,
audio_config: BufferedStep.AudioConfig,
step: *BufferedStep,

pub fn init(
    allocator: std.mem.Allocator,
    name: []const u8,
    in_sample_rate: usize,
    in_channels: usize,
    expect_output: bool,
) !*Self {
    if (in_channels > max_in_channels) {
        return error.TooManyChannels;
    }

    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const in_buffer_size = calcBufferSizeForWindow(in_sample_rate, in_buffer_ms);

    var out_segment = try Segment.initWithCapacity(allocator, 1, in_buffer_size);
    errdefer out_segment.deinit();

    const channel_rolling_avgs = try allocator.alloc(RollingAverage, in_channels);
    errdefer allocator.free(channel_rolling_avgs);
    for (0..in_channels) |i| {
        const rolling_avg_len = calcNumStepsForWindow(in_buffer_size, in_sample_rate, best_channel_rolling_avg_ms);
        channel_rolling_avgs[i] = try RollingAverage.init(allocator, rolling_avg_len, 1);
    }

    self.* = .{
        .allocator = allocator,
        .out_segment = out_segment,
        .out_result = .{
            .metadata = .{},
            .segment = &self.out_segment,
        },
        .audio_config = .{
            .buffer_size = in_buffer_size,
            .in_channels = in_channels,
            .in_sample_rate = in_sample_rate,
            .out_channels = 1,
            .out_sample_rate = in_sample_rate,
            .expect_output = expect_output,
        },
        .channel_rolling_avgs = channel_rolling_avgs,
        .step = undefined,
    };

    self.step = try BufferedStep.init(
        allocator,
        name,
        self.audio_config,
        BufferedStep.Processor.forContext(self),
    );
    errdefer self.step.deinit();

    return self;
}

pub fn deinit(self: *Self) void {
    self.step.deinit();
    self.out_segment.deinit();
    for (self.channel_rolling_avgs) |*rolling_avg| {
        rolling_avg.deinit();
    }
    self.allocator.free(self.channel_rolling_avgs);
    self.allocator.destroy(self);
}

pub fn process(self: *Self, prev_result: *const BufferedStep.Result) *const BufferedStep.Result {
    const in_segment = prev_result.segment;
    const n_channels = in_segment.channel_pcm_buf.len;

    if (n_channels != self.audio_config.in_channels) {
        @setCold(true);
        std.debug.panic("BufferedMixer received {d} channels, expected {d}", .{ n_channels, self.audio_config.in_channels });
    } else if (in_segment.length() != self.audio_config.buffer_size) {
        @setCold(true);
        std.debug.panic("BufferedMixer received {d} samples, expected {d}", .{ in_segment.length(), self.audio_config.buffer_size.? });
    }

    const metadata = &self.out_result.metadata;
    metadata.* = prev_result.metadata;

    if (n_channels == 2) {
        // Find the volume ratio between channels. In F1, one of the channels is usually
        // quieter and contains less engine noise, while team radio is equally loud on both.
        var left_rolling_avg = &self.channel_rolling_avgs[left_idx];
        var right_rolling_avg = &self.channel_rolling_avgs[right_idx];

        const left = in_segment.channel_pcm_buf[left_idx];
        const right = in_segment.channel_pcm_buf[right_idx];

        // instantaneous volume ratio (used for metadata)
        const left_vol = audio_utils.rmsVolume(left);
        const right_vol = audio_utils.rmsVolume(right);
        const min_vol = @min(left_vol, right_vol);
        const max_vol = @max(left_vol, right_vol);
        const instant_ratio = min_vol / max_vol;

        // long term volume ratio (used to pick the best channel)
        const left_avg = left_rolling_avg.push(left_vol);
        const right_avg = right_rolling_avg.push(right_vol);
        const louder_chan_index: usize = if (left_avg > right_avg) left_idx else right_idx;
        const quieter_chan_index: usize = if (left_avg > right_avg) right_idx else left_idx;

        const max_avg = @max(left_avg, right_avg);
        const min_avg = @min(left_avg, right_avg);
        const avg_ratio = max_avg / min_avg;

        if (std.math.isInf(avg_ratio)) {
            // we divided by zero, meaning the quieter channel is completely silent
            self.best_channel = louder_chan_index;
        } else if (avg_ratio > 1 + switch_best_threshold and self.best_channel != quieter_chan_index) {
            log.debug(
                "BufferedMixer '{s}': switching to channel {d} at sample {d}",
                .{ self.step.name, quieter_chan_index, in_segment.index },
            );
            self.best_channel = quieter_chan_index;
        }

        metadata.volume_max = max_vol;
        metadata.volume_min = min_vol;
        metadata.volume_ratio = instant_ratio;
    }

    const in_channel = in_segment.channel_pcm_buf[self.best_channel];
    const out_channel = self.out_segment.writablePCM()[0];

    @memcpy(out_channel, in_channel);

    self.out_segment.index = in_segment.index;
    return &self.out_result;
}

/// Calculates the buffer size to cover a certain length of audio at given sample rate
fn calcBufferSizeForWindow(sample_rate: usize, ms: usize) usize {
    const sample_rate_f: f64 = @floatFromInt(sample_rate);
    const ms_f: f64 = @floatFromInt(ms);

    const buffer_size_f = (sample_rate_f / 1000) * ms_f;
    return @intFromFloat(buffer_size_f);
}

/// Calculated the number of `buffer_size`-sized windows it takes to cover a certain time span (`ms`) at given `sample_rate`
fn calcNumStepsForWindow(buffer_size: usize, sample_rate: usize, ms: usize) usize {
    const buffer_size_f: f64 = @floatFromInt(buffer_size);
    const sample_rate_f: f64 = @floatFromInt(sample_rate);
    const ms_f: f64 = @floatFromInt(ms);

    const buffers_per_ms: f64 = (sample_rate_f / buffer_size_f) / 1000;

    const n_buffers_f = ms_f * buffers_per_ms;
    const n_buffers: usize = @intFromFloat(n_buffers_f);

    return @max(1, n_buffers);
}

test "calculations" {
    const t = std.testing;

    const sample_rate = 48000;
    const window_ms = 100;

    // 4800 sample buffer represents 100ms at 48kHz
    const buffer_size_for_window = calcBufferSizeForWindow(sample_rate, window_ms);
    try t.expectEqual(4800, buffer_size_for_window);

    // 200 buffers (each 100ms long) represent 20s at 48kHz with buffer size calculated above
    const long_term_ms = 20_000;
    const rolling_avg_size = calcNumStepsForWindow(buffer_size_for_window, sample_rate, long_term_ms);
    try t.expectEqual(200, rolling_avg_size);
}

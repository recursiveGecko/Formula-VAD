const std = @import("std");
const log = std.log.scoped(.vad_sm);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const RollingAverage = @import("../structures/RollingAverage.zig");
const VADPipeline = @import("./VADPipeline.zig");
const BufferedFFT = @import("./BufferedFFT.zig");

const Self = @This();

pub const SpeechState = enum {
    closed,
    opening,
    open,
    closing,
};

pub const Result = struct {
    pub const RecordingState = enum {
        none,
        started,
        completed,
        aborted,
    };

    recording_state: RecordingState,
    sample_number: u64,
};

pub const Config = struct {
    /// Speech band
    speech_min_freq: f32 = 500,
    speech_max_freq: f32 = 2000,
    /// Time span for tracking long-term volume in speech band and initial value
    long_term_speech_avg_sec: f32 = 180,
    initial_long_term_avg: ?f64 = 0.005,
    /// Time span for short-term trigger in speech band
    short_term_speech_avg_sec: f32 = 0.2,
    /// Primary trigger for speech when short term avg in denoised speech band is this
    /// many times higher than long term avg
    speech_threshold_factor: f32 = 10,
    /// Secondary trigger that compares volume in L and R channels before denoising
    channel_vol_ratio_avg_sec: f32 = 0.5,
    channel_vol_ratio_threshold: f32 = 0.5,
    /// Conditions need to be met for this many consecutive seconds before speech is triggered
    min_consecutive_sec_to_open: f32 = 0.2,
    /// Maximum gap where speech is still considered to be ongoing
    max_speech_gap_sec: f32 = 2,
    /// Minimum duration of speech segments
    min_vad_duration_sec: f32 = 0.7,
};

allocator: Allocator,
sample_rate: usize,
n_channels: usize,
config: Config,
// "Read only" access to FFT pipeline for calculating volume in speech band
buffered_fft: BufferedFFT,
speech_state: SpeechState = .closed,
long_term_speech_volume: RollingAverage,
short_term_speech_volume: RollingAverage,
channel_vol_ratio: RollingAverage,
// Start and stop samples of the ongoing speech segment
speech_start_index: ?u64 = null,
speech_end_index: ?u64 = null,
// Volume ratio between channels for ongoing speech segments
channel_vol_ratio_sum: f32 = 0,
channel_vol_ratio_count: usize = 0,
vad_threshold_met_cumulative_sec: f32 = 0,
// Stores temporary results when calculating per-channel volumes
temp_channel_volumes: []f32,
/// End result - VAD segments
vad_segments: std.ArrayList(VADPipeline.SpeechSegment),

pub fn init(allocator: Allocator, config: Config, vad: VADPipeline) !Self {
    const sample_rate = vad.sample_rate;
    const sample_rate_f: f32 = @floatFromInt(sample_rate);
    const n_channels = vad.n_channels;
    const fft_size = vad.config.fft_size;
    const fft_size_f: f32 = @floatFromInt(fft_size);

    const eval_per_sec = sample_rate_f / fft_size_f;
    const long_term_avg_len: usize = @intFromFloat(eval_per_sec * config.long_term_speech_avg_sec);
    const short_term_avg_len: usize = @intFromFloat(eval_per_sec * config.short_term_speech_avg_sec);
    const channel_vol_ratio_len: usize = @intFromFloat(eval_per_sec * config.channel_vol_ratio_avg_sec);

    var long_term_speech_avg = try RollingAverage.init(
        allocator,
        @max(1, long_term_avg_len),
        config.initial_long_term_avg,
    );
    errdefer long_term_speech_avg.deinit();

    var short_term_speech_avg = try RollingAverage.init(
        allocator,
        @max(1, short_term_avg_len),
        null,
    );
    errdefer short_term_speech_avg.deinit();

    var channel_vol_ratio = try RollingAverage.init(
        allocator,
        channel_vol_ratio_len,
        null,
    );
    errdefer channel_vol_ratio.deinit();

    const temp_channel_volumes = try allocator.alloc(f32, n_channels);
    errdefer allocator.free(temp_channel_volumes);

    var vad_segments = try std.ArrayList(VADPipeline.SpeechSegment).initCapacity(allocator, 100);
    errdefer vad_segments.deinit();

    var self = Self{
        .allocator = allocator,
        .config = config,
        .buffered_fft = vad.buffered_fft,
        .sample_rate = sample_rate,
        .n_channels = n_channels,
        .long_term_speech_volume = long_term_speech_avg,
        .short_term_speech_volume = short_term_speech_avg,
        .channel_vol_ratio = channel_vol_ratio,
        .temp_channel_volumes = temp_channel_volumes,
        .vad_segments = vad_segments,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    self.long_term_speech_volume.deinit();
    self.short_term_speech_volume.deinit();
    self.channel_vol_ratio.deinit();
    self.allocator.free(self.temp_channel_volumes);
    self.vad_segments.deinit();
}

pub fn run(
    self: *Self,
    fft_result: *const BufferedFFT.Result,
) !Result {
    const sample_rate_f: f32 = @floatFromInt(self.sample_rate);
    const config = self.config;

    // Find the average volume in the speech band
    try self.buffered_fft.averageVolumeInBand(
        fft_result,
        config.speech_min_freq,
        config.speech_max_freq,
        self.temp_channel_volumes,
    );

    var min_volume: f32 = 999;
    var max_volume: f32 = 0;
    for (self.temp_channel_volumes) |volume| {
        if (volume < min_volume) min_volume = volume;
        if (volume > max_volume) max_volume = volume;
    }

    // Number of consecutive samples above the threshold before the VAD opens
    const min_consecutive_to_open: usize = @intFromFloat(sample_rate_f * config.min_consecutive_sec_to_open);
    // Number of consecutive samples below the threshold before the VAD closes
    const max_gap_samples: usize = @intFromFloat(sample_rate_f * config.max_speech_gap_sec);

    // Use the minimum for activation as it's likely the one containing less engine noise, and therefore more accurate
    const short_term = self.short_term_speech_volume.push(min_volume);
    const channel_vol_ratio = self.channel_vol_ratio.push(fft_result.vad_metadata.volume_ratio orelse 0);

    const threshold_base = self.long_term_speech_volume.last_avg orelse config.initial_long_term_avg orelse short_term;
    const threshold = threshold_base * config.speech_threshold_factor;
    const threshold_met = short_term > threshold and channel_vol_ratio > config.channel_vol_ratio_threshold;

    // Do not update the long term average if the threshold is met
    // TODO: This is problematic, if the threshold happens to be set too low, it would cause
    // continuous VAD activation which would prevent self-correction
    if (!threshold_met) {
        _ = self.long_term_speech_volume.push(min_volume);
    }

    // VAD segment to emit after speech ends
    var vad_machine_result: Result = .{
        .recording_state = .none,
        .sample_number = 0,
    };

    const from_state: SpeechState = self.speech_state;

    // Speech state machine
    switch (self.speech_state) {
        .closed => {
            if (threshold_met) {
                self.speech_state = .opening;
                self.speech_start_index = fft_result.index;
                log.debug("Speech opening at sample {d}", .{self.speech_start_index.?});
            }
        },
        .opening => {
            const samples_since_opening = fft_result.index - self.speech_start_index.?;
            const opening_duration_met = samples_since_opening >= min_consecutive_to_open;

            if (threshold_met and opening_duration_met) {
                self.speech_state = .open;
                vad_machine_result = .{
                    .recording_state = .started,
                    .sample_number = self.getOffsetRecordingStart(self.speech_start_index.?),
                };
                log.debug("Speech open", .{});
            } else if (!threshold_met) {
                self.speech_state = .closed;
                log.debug("Speech cancelled", .{});
            }
        },
        .open => {
            if (!threshold_met) {
                self.speech_state = .closing;
                self.speech_end_index = fft_result.index;
                log.debug("Speech ending at sample {d}", .{self.speech_end_index.?});
            }
        },
        .closing => {
            const samples_since_closing = fft_result.index - self.speech_end_index.?;
            const closing_duration_met = samples_since_closing >= max_gap_samples;

            if (threshold_met) {
                self.speech_state = .open;
                log.debug("Speech resumed", .{});
            } else if (closing_duration_met) {
                self.speech_state = .closed;
                log.debug("Speech ended", .{});
                vad_machine_result = try self.onSpeechEnd();
            }
        },
    }

    const to_state: SpeechState = self.speech_state;
    self.trackSpeechStats(fft_result, threshold_met, from_state, to_state);

    return vad_machine_result;
}

fn trackSpeechStats(
    self: *Self,
    fft_result: *const BufferedFFT.Result,
    threshold_met: bool,
    from_state: SpeechState,
    to_state: SpeechState,
) void {
    const sample_rate_f: f32 = @floatFromInt(self.sample_rate);
    const input_length_sec = @as(f32, @floatFromInt(fft_result.fft_size)) / sample_rate_f;

    if (from_state == .closed and to_state == .opening) {
        self.channel_vol_ratio_sum = fft_result.vad_metadata.volume_ratio orelse 0;
        self.channel_vol_ratio_count = 1;
        self.vad_threshold_met_cumulative_sec = input_length_sec;
    } else if (from_state == .open) {
        self.channel_vol_ratio_sum += fft_result.vad_metadata.volume_ratio orelse 0;
        self.channel_vol_ratio_count += 1;

        if (threshold_met) {
            self.vad_threshold_met_cumulative_sec += input_length_sec;
        }
    }
}

fn onSpeechEnd(self: *Self) !Result {
    const sample_rate_f: f32 = @floatFromInt(self.sample_rate);

    const sample_from = self.speech_start_index.?;
    const sample_to = self.speech_end_index.?;
    const length_samples = sample_to - sample_from;
    const length_sec = @as(f32, @floatFromInt(length_samples)) / sample_rate_f;

    const config = self.config;

    const speech_duration_met = length_sec >= config.min_vad_duration_sec;
    const avg_channel_vol_ratio = self.channel_vol_ratio_sum / @as(f32, @floatFromInt(self.channel_vol_ratio_count));

    if (speech_duration_met) {
        const segment = VADPipeline.SpeechSegment{
            .sample_from = self.getOffsetRecordingStart(sample_from),
            .sample_to = self.getOffsetRecordingEnd(sample_to),
            .avg_channel_vol_ratio = avg_channel_vol_ratio,
            .vad_met_sec = self.vad_threshold_met_cumulative_sec,
        };
        _ = try self.vad_segments.append(segment);

        log.info(
            "VAD Segment: {d: >6.2}s  | Avg. vol ratio: {d: >5.2} ({d: >4}) | Actual VAD duration: {d: >4.1}s ",
            .{
                length_sec,
                avg_channel_vol_ratio,
                self.channel_vol_ratio_count,
                self.vad_threshold_met_cumulative_sec,
            },
        );
    }

    if (speech_duration_met) {
        return .{
            .recording_state = .completed,
            .sample_number = self.getOffsetRecordingEnd(sample_to),
        };
    } else {
        return .{
            .recording_state = .aborted,
            .sample_number = 0,
        };
    }
}

/// Add a couple of seconds of margin to the start of the segment
pub fn getOffsetRecordingStart(self: Self, vad_from: u64) u64 {
    const sample_rate_f: f32 = @floatFromInt(self.sample_rate);
    const start_buffer: usize = @intFromFloat(sample_rate_f * 2);
    const record_from = vad_from - @min(start_buffer, vad_from);
    return record_from;
}

/// Add a couple of seconds of margin to the end of the segment
pub fn getOffsetRecordingEnd(self: Self, vad_to: u64) u64 {
    const sample_rate_f: f32 = @floatFromInt(self.sample_rate);
    const end_buffer: usize = @intFromFloat(sample_rate_f * 2);
    const record_to = vad_to + end_buffer;
    return record_to;
}

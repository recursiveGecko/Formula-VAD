const std = @import("std");
const log = std.log.scoped(.vad_sm);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const RollingAverage = @import("../structures/RollingAverage.zig");
const VAD = @import("./VAD.zig");
const PipelineFFT = @import("./PipelineFFT.zig");

const Self = @This();

pub const SpeechState = enum {
    closed,
    opening,
    open,
    closing,
};

pub const Config = struct {
    /// Speech band
    speech_min_freq: f32 = 100,
    speech_max_freq: f32 = 1500,
    /// Time span for tracking long-term volume in speech band and initial value
    long_term_speech_avg_sec: f32 = 180,
    initial_long_term_avg: ?f64 = 0.005,
    /// Time span for short-term trigger in speech band
    short_term_speech_avg_sec: f32 = 0.2,
    /// Primary trigger for speech when short term avg in denoised speech band is this
    /// many times higher than long term avg
    speech_threshold_factor: f32 = 18,
    /// Secondary trigger that compares volume in L and R channels before denoising
    channel_vol_ratio_avg_sec: f32 = 0.5,
    channel_vol_ratio_threshold: f32 = 0.5,
    /// Conditions need to be met for this many consecutive milliseconds before speech is triggered
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
pipeline_fft: PipelineFFT,
speech_state: SpeechState = .closed,
long_term_speech_volume: RollingAverage,
short_term_speech_volume: RollingAverage,
channel_vol_ratio: RollingAverage,
// Start and stop samples of the ongoing speech segment
speech_start_index: u64 = 0,
speech_end_index: u64 = 0,
// RNNoise VAD for ongoing speech segments
speech_rnn_vad: f32 = 0,
speech_rnn_vad_count: usize = 0,
// Stores temporary results when calculating per-channel volumes
temp_channel_volumes: []f32,
// Volume ratio between channels for ongoing speech segments
speech_vol_ratio: f32 = 0,
speech_vol_ratio_count: usize = 0,
/// End result - VAD segments
vad_segments: std.ArrayList(VAD.VADSpeechSegment),

pub fn init(allocator: Allocator, config: Config, vad: VAD) !Self {
    const sample_rate = vad.sample_rate;
    const n_channels = vad.n_channels;
    const fft_size = vad.config.fft_size;

    const eval_per_sec = @intToFloat(f32, sample_rate) / @intToFloat(f32, fft_size);
    const long_term_avg_len = @floatToInt(usize, eval_per_sec * config.long_term_speech_avg_sec);
    const short_term_avg_len = @floatToInt(usize, eval_per_sec * config.short_term_speech_avg_sec);
    const channel_vol_ratio_len = @floatToInt(usize, eval_per_sec * config.channel_vol_ratio_avg_sec);

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

    var vad_segments = try std.ArrayList(VAD.VADSpeechSegment).initCapacity(allocator, 100);
    errdefer vad_segments.deinit();

    var self = Self{
        .allocator = allocator,
        .config = config,
        .pipeline_fft = vad.pipeline_fft,
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
    fft_input: *const VAD.AnalyzedSegment,
    fft_result: *const PipelineFFT.Result,
) !VAD.VADMachineResult {
    const sample_rate_f = @intToFloat(f32, self.sample_rate);
    const config = self.config;

    // Find the average volume in the speech band
    try self.pipeline_fft.averageVolumeInBand(
        fft_result.*,
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
    const min_consecutive_to_open = @floatToInt(usize, sample_rate_f * config.min_consecutive_sec_to_open);
    // Number of consecutive samples below the threshold before the VAD closes
    const max_gap_samples = @floatToInt(usize, sample_rate_f * config.max_speech_gap_sec);

    // Use the minimum for activation as it's likely the one containing less engine noise, and therefore more accurate
    const short_term = self.short_term_speech_volume.push(min_volume);
    const channel_vol_ratio = self.channel_vol_ratio.push(fft_input.volume_ratio);

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
    var vad_machine_result: VAD.VADMachineResult = .{
        .recording_state = .none,
        .sample_number = 0,
    };

    // Speech state machine
    switch (self.speech_state) {
        .closed => {
            if (threshold_met) {
                self.speech_state = .opening;
                self.speech_start_index = fft_result.index;
            }

            self.trackSpeechStats(fft_input, .closed, self.speech_state);
        },
        .opening => {
            const samples_since_opening = fft_result.index - self.speech_start_index;
            const opening_duration_met = samples_since_opening >= min_consecutive_to_open;

            if (threshold_met and opening_duration_met) {
                self.speech_state = .open;
                vad_machine_result = .{
                    .recording_state = .started,
                    .sample_number = self.getOffsetRecordingStart(self.speech_start_index),
                };
            } else if (!threshold_met) {
                self.speech_state = .closed;
            }

            self.trackSpeechStats(fft_input, .opening, self.speech_state);
        },
        .open => {
            if (!threshold_met) {
                self.speech_state = .closing;
                self.speech_end_index = fft_result.index;
            }

            self.trackSpeechStats(fft_input, .open, self.speech_state);
        },
        .closing => {
            const samples_since_closing = fft_result.index - self.speech_end_index;
            const closing_duration_met = samples_since_closing >= max_gap_samples;

            if (threshold_met) {
                self.speech_state = .open;
            } else if (closing_duration_met) {
                self.speech_state = .closed;
                vad_machine_result = try self.onSpeechEnd();
            }

            self.trackSpeechStats(fft_input, .closing, self.speech_state);
        },
    }

    // log.debug(
    //     "Speech threshold: {d: >10.5} Loudness: {d: >10.5}   Threshold: {any: >6}   Status: {s: >9}",
    //     .{ threshold * 100, short_term * 100, threshold_met, @tagName(self.speech_state) },
    // );

    return vad_machine_result;
}

/// Track RNNoise's own VAD score during speech segments
fn trackSpeechStats(
    self: *Self,
    fft_input: *const VAD.AnalyzedSegment,
    from_state: SpeechState,
    to_state: SpeechState,
) void {
    if (from_state == .closed and to_state == .opening) {
        self.speech_rnn_vad = fft_input.vad orelse 0;
        self.speech_rnn_vad_count = 1;
        self.speech_vol_ratio = fft_input.volume_ratio;
        self.speech_vol_ratio_count = 1;
    } else if (from_state == .opening or from_state == .open) {
        self.speech_rnn_vad += fft_input.vad orelse 0;
        self.speech_rnn_vad_count += 1;
        self.speech_vol_ratio += fft_input.volume_ratio;
        self.speech_vol_ratio_count += 1;
    }
}

fn onSpeechEnd(self: *Self) !VAD.VADMachineResult {
    const sample_from = self.speech_start_index;
    const sample_to = self.speech_end_index;
    const length_samples = sample_to - sample_from;

    const sample_rate_f = @intToFloat(f32, self.sample_rate);
    const config = self.config;

    const length_realtime = @intToFloat(f32, length_samples) / sample_rate_f;
    const speech_duration_met = length_realtime >= config.min_vad_duration_sec;

    const avg_rnn_vad = self.speech_rnn_vad / @intToFloat(f32, self.speech_rnn_vad_count);
    const avg_speech_vol_ratio = self.speech_vol_ratio / @intToFloat(f32, self.speech_vol_ratio_count);

    if (speech_duration_met) {
        const segment = VAD.VADSpeechSegment{
            .sample_from = self.getOffsetRecordingStart(sample_from),
            .sample_to = self.getOffsetRecordingEnd(sample_to),
            .debug_rnn_vad = avg_rnn_vad,
            .debug_avg_speech_vol_ratio = avg_speech_vol_ratio,
        };
        _ = try self.vad_segments.append(segment);

        const debug_len_s = @intToFloat(f32, length_samples) / sample_rate_f;

        log.debug(
            "VAD Segment: {d: >6.2}s  | Avg. RNNoise VAD: {d: >6.2}% | Avg. vol ratio: {d: >5.2} ",
            .{ debug_len_s, avg_rnn_vad * 100, avg_speech_vol_ratio },
        );
    }

    if (speech_duration_met) {
        return .{
            .recording_state = .completed,
            .sample_number = self.getOffsetRecordingEnd(self.speech_end_index),
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
    const sample_rate_f = @intToFloat(f32, self.sample_rate);
    const start_buffer = @floatToInt(usize, sample_rate_f * 2);
    const record_from = if (start_buffer > vad_from) 0 else vad_from - start_buffer;
    return record_from;
}

/// Add a couple of seconds of margin to the end of the segment 
pub fn getOffsetRecordingEnd(self: Self, vad_to: u64) u64 {
    const sample_rate_f = @intToFloat(f32, self.sample_rate);
    const end_buffer = @floatToInt(usize, sample_rate_f * 2);
    const record_to = vad_to + end_buffer;
    return record_to;
}

const std = @import("std");
const log = std.log.scoped(.vad_sm);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const RollingAverage = @import("../structures/RollingAverage.zig");
const VADPipeline = @import("./VADPipeline.zig");
const BufferedFFT = @import("./BufferedFFT.zig");
const BufferedSileroVAD = @import("./BufferedSileroVAD.zig");

const Self = @This();

pub const SpeechState = enum {
    closed,
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
    vad_threshold: f32 = 0.8,
    /// Time span for short-term trigger in speech band
    rolling_vad_avg_sec: f32 = 0.2,
    /// Secondary trigger that compares volume in L and R channels before denoising
    rolling_channel_vol_ratio_avg_sec: f32 = 0.5,
    rolling_channel_vol_ratio_avg_threshold: f32 = 0.4,
    /// Conditions need to be met for this many consecutive seconds before speech is triggered
    min_consecutive_sec_to_open: f32 = 0.2,
    /// Maximum gap where speech is still considered to be ongoing
    max_speech_gap_sec: f32 = 1,
    /// Minimum duration of speech segments
    min_vad_duration_sec: f32 = 1,
};

allocator: Allocator,
sample_rate: usize,
n_channels: usize,
config: Config,
// "Read only" access to FFT pipeline for calculating volume in speech band
// buffered_fft: BufferedFFT,
speech_state: SpeechState = .closed,
rolling_vad_avg: RollingAverage,
rolling_channel_vol_ratio: RollingAverage,
// Start and stop samples of the ongoing speech segment
speech_start_index: ?u64 = null,
speech_end_index: ?u64 = null,
// RNNoise VAD for ongoing speech segments
silero_vad_sum: f32 = 0,
silero_vad_count: usize = 0,
// Volume ratio between channels for ongoing speech segments
channel_vol_ratio_sum: f32 = 0,
channel_vol_ratio_count: usize = 0,
vad_threshold_met_cumulative_sec: f32 = 0,
/// End result - VAD segments
vad_segments: std.ArrayList(VADPipeline.SpeechSegment),

pub fn init(allocator: Allocator, config: Config, vad: VADPipeline) !Self {
    const sample_rate = vad.sample_rate;
    const n_channels = vad.n_channels;
    const fft_size = vad.config.fft_size;

    const eval_per_sec = @intToFloat(f32, sample_rate) / @intToFloat(f32, fft_size);
    const rolling_vad_avg_len = @floatToInt(usize, eval_per_sec * config.rolling_vad_avg_sec);
    const rolling_channel_vol_ratio_len = @floatToInt(usize, eval_per_sec * config.rolling_channel_vol_ratio_avg_sec);

    var rolling_vad_avg = try RollingAverage.init(
        allocator,
        @max(1, rolling_vad_avg_len),
        null,
    );
    errdefer rolling_vad_avg.deinit();

    var rolling_channel_vol_ratio = try RollingAverage.init(
        allocator,
        rolling_channel_vol_ratio_len,
        null,
    );
    errdefer rolling_channel_vol_ratio.deinit();

    var vad_segments = try std.ArrayList(VADPipeline.SpeechSegment).initCapacity(allocator, 1000);
    errdefer vad_segments.deinit();

    var self = Self{
        .allocator = allocator,
        .config = config,
        .sample_rate = sample_rate,
        .n_channels = n_channels,
        .rolling_vad_avg = rolling_vad_avg,
        .rolling_channel_vol_ratio = rolling_channel_vol_ratio,
        .vad_segments = vad_segments,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    self.rolling_vad_avg.deinit();
    self.rolling_channel_vol_ratio.deinit();
    self.vad_segments.deinit();
}

pub fn run(
    self: *Self,
    result: *const BufferedSileroVAD.Result,
) !Result {
    const vad: f32 = result.vad_min.?;

    const sample_rate_f = @intToFloat(f32, self.sample_rate);

    // Parameters
    const max_silence_samples = @floatToInt(
        usize,
        sample_rate_f * self.config.max_speech_gap_sec,
    );
    const on_threshold = self.config.vad_threshold;
    const off_threshold = on_threshold * 0.8;

    const curr_sample_index = result.index.?;

    // VAD segment to emit after speech ends
    var vad_machine_result: Result = .{
        .recording_state = .none,
        .sample_number = 0,
    };

    var from_state: SpeechState = val: {
        if (self.speech_start_index == null) break :val .closed;
        if (self.speech_end_index == null) break :val .open;
        break :val .closing;
    };

    var to_state: SpeechState = from_state;

    // 1. Start speaking
    if (vad >= on_threshold and self.speech_start_index == null) {
        self.speech_start_index = curr_sample_index;

        vad_machine_result = .{
            .recording_state = .started,
            .sample_number = self.getOffsetRecordingStart(self.speech_start_index.?),
        };

        to_state = .open;
    }

    // 2. Maybe stop speaking
    if (vad < off_threshold and self.speech_end_index == null) {
        self.speech_end_index = curr_sample_index;
        to_state = .closing;
    }

    // 3. Continue speaking
    if (vad >= on_threshold and self.speech_end_index != null) {
        self.speech_end_index = null;
        to_state = .open;
    }

    // 4. Stop speaking
    if (self.speech_start_index != null and
        self.speech_end_index != null and
        curr_sample_index - self.speech_end_index.? >= max_silence_samples)
    {
        vad_machine_result = try self.onSpeechEnd();

        self.speech_start_index = null;
        self.speech_end_index = null;
        to_state = .closed;
    }

    self.trackSpeechStats(result, from_state, to_state);

    return vad_machine_result;
}

/// Track RNNoise's own VAD score during speech segments
fn trackSpeechStats(
    self: *Self,
    result: *const BufferedSileroVAD.Result,
    from_state: SpeechState,
    to_state: SpeechState,
) void {
    const vad = result.vad.?;
    const sample_rate_f = @intToFloat(f32, self.sample_rate);
    const input_length_sec = @intToFloat(f32, result.input_length.?) / sample_rate_f;

    if (from_state == .closed and to_state == .open) {
        self.channel_vol_ratio_sum = result.metadata.?.volume_ratio orelse 0;
        self.channel_vol_ratio_count = 1;
        self.silero_vad_sum = result.vad.?;
        self.silero_vad_count = 1;

        self.vad_threshold_met_cumulative_sec = input_length_sec;
    } else if (from_state == .open) {
        self.channel_vol_ratio_sum += result.metadata.?.volume_ratio orelse 0;
        self.channel_vol_ratio_count += 1;
        self.silero_vad_sum += result.vad.?;
        self.silero_vad_count += 1;

        if (vad >= self.config.vad_threshold) {
            self.vad_threshold_met_cumulative_sec += input_length_sec;
        }
    }
}

fn onSpeechEnd(self: *Self) !Result {
    const sample_from = self.speech_start_index.?;
    const sample_to = self.speech_end_index.?;
    const length_samples = sample_to - sample_from;

    const sample_rate_f = @intToFloat(f32, self.sample_rate);
    const config = self.config;

    const speech_duration_met = self.vad_threshold_met_cumulative_sec >= config.min_vad_duration_sec;

    const avg_silero_vad = self.silero_vad_sum / @intToFloat(f32, self.silero_vad_count);
    const avg_channel_vol_ratio = self.channel_vol_ratio_sum / @intToFloat(f32, self.channel_vol_ratio_count);

    if (speech_duration_met) {
        const segment = VADPipeline.SpeechSegment{
            .sample_from = self.getOffsetRecordingStart(sample_from),
            .sample_to = self.getOffsetRecordingEnd(sample_to),
            .avg_vad = avg_silero_vad,
            .avg_channel_vol_ratio = avg_channel_vol_ratio,
            .vad_met_sec = self.vad_threshold_met_cumulative_sec,
        };
        _ = try self.vad_segments.append(segment);

        const debug_len_s = @intToFloat(f32, length_samples) / sample_rate_f;

        log.info(
            "VAD Segment: {d: >6.2}s  | Avg. VAD: {d: >6.2}% | Avg. vol ratio: {d: >5.2} | Actual VAD duration: {d: >4.1}s ",
            .{
                debug_len_s,
                avg_silero_vad * 100,
                avg_channel_vol_ratio,
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

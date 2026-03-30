const std = @import("std");
const audio_utils = @import("../audio_utils.zig");
const SileroVAD = @import("../SileroVAD.zig");
const AudioPipeline = @import("../AudioPipeline.zig");
const BufferedStep = @import("./BufferedStep.zig");
const BufferedFFT = @import("./BufferedFFT.zig");
const RollingAverage = @import("../structures/RollingAverage.zig");

const SileroVADMachine = @This();

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
    instant_silero_vad: f32,
};

pub const Config = struct {
    on_threshold: f32 = 0.6,
    off_threshold: f32 = 0.4,
    min_speech_duration_ms: f32 = 350,
    max_silence_between_speech_ms: f32 = 1500,
    pad_start_ms: usize = 1000,
    pad_end_ms: usize = 500,
    // supporting activation parameters
    short_term_avg_ms: f32 = 500,
    long_term_avg_ms: f32 = 30_000,
    min_channel_vol_ratio: f32 = 0.5,
};

pub const FrameMetrics = struct {
    first_sample_index: u64,
    length: u64,
    vad: f32,
    channel_vol_ratio: ?f32,
    speech_band_vol: f32,
};

allocator: std.mem.Allocator,
config: Config,
vad_segments: std.ArrayList(AudioPipeline.SpeechSegment),
/// Root sample rate multiplier (as defined in `BufferedStep`)
root_sr_mul: f64,
sample_rate: usize,
// VAD state machine
start_sample: ?usize = null,
end_sample: ?usize = null,
status: SpeechState = .closed,
rolling_speech_band_vol: RollingAverage,
/// whether speech is "active", according to our caller
awaiting_close: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    config: Config,
    /// Root sample rate multiplier (as defined in `BufferedStep`)
    root_sr_mul: f64,
    sample_rate: usize,
) !SileroVADMachine {
    const rolling_speech_band_vol = try RollingAverage.init(
        allocator,
        audio_utils.secondsToSamples(config.long_term_avg_ms / 1000, sample_rate),
        null,
    );
    errdefer rolling_speech_band_vol.deinit();

    return SileroVADMachine{
        .allocator = allocator,
        .config = config,
        .root_sr_mul = root_sr_mul,
        .sample_rate = sample_rate,
        .vad_segments = .empty,
        .rolling_speech_band_vol = rolling_speech_band_vol,
    };
}

pub fn deinit(self: *SileroVADMachine) void {
    self.rolling_speech_band_vol.deinit();
    self.vad_segments.deinit(self.allocator);
}

pub fn run(
    self: *SileroVADMachine,
    prev_result: *const BufferedStep.Result,
    fft_result: *const BufferedFFT.FFTResult,
) !Result {
    std.debug.assert(prev_result.segment.nChannels() == 1);

    const first_sample_index = prev_result.segment.index;
    const length = prev_result.segment.length();
    const silero_vad = prev_result.metadata.silero_vad.?;

    return self.run2(FrameMetrics{
        .first_sample_index = first_sample_index,
        .length = length,
        .vad = silero_vad,
        .channel_vol_ratio = prev_result.metadata.volume_ratio.?,
        .speech_band_vol = try fft_result.averageVolumeInBand(100, 300, false),
    });
}

pub fn run2(
    self: *SileroVADMachine,
    metrics: FrameMetrics,
) !Result {
    const cfg = self.config;

    const first_sample_index = metrics.first_sample_index;
    const last_sample_index = metrics.first_sample_index + metrics.length - 1;
    const in_sample_rate = self.sample_rate;

    // const avg_speech_band_vol = self.rolling_speech_band_vol.push(metrics.speech_band_vol);
    // const speech_band_ratio = metrics.speech_band_vol / avg_speech_band_vol;
    // const speech_band_activation = activationFn(1, 2, speech_band_ratio);
    // _ = speech_band_activation; // autofix

    const vad = metrics.vad;

    // var vad = (metrics.vad * 2 + speech_band_activation) / 3;
    // if (metrics.vad > 0.4) {
    //     vad = metrics.vad;
    // }
    // if (speech_band_ratio > 1.5 and metrics.vad > 0.3) {
    //     vad = speech_band_activation;
    // }

    // if (metrics.vad > 0.5) {
    //     // std.debug.print("{d:.0}%:  {d:.2}x = {d:.0}%\n", .{ metrics.vad * 100, speech_band_ratio, vad * 100 });
    // }
    // const vad = metrics.vad;

    // std.debug.print("{d:5.3}\n", .{vad});

    switch (self.status) {
        .closed => {
            if (vad >= cfg.on_threshold) {
                // 1. Start opening sequence
                self.start_sample = first_sample_index;
                self.status = .opening;
            }
        },
        .opening => {
            const speech_duration_samples_f: f32 = @floatFromInt(last_sample_index - self.start_sample.?);
            const samples_per_ms = @as(f32, @floatFromInt(in_sample_rate)) / 1000;
            const ms_since_opening = speech_duration_samples_f / samples_per_ms;

            // std.debug.print("{any} - {d:.2} - {d:.1}\n", .{ self.status, vad, speech_duration_ms });

            if (vad < cfg.on_threshold) {
                self.status = .closing;
                self.end_sample = last_sample_index;
            }

            if (ms_since_opening >= cfg.min_speech_duration_ms) {
                self.status = .open;
                self.awaiting_close = true;

                return Result{
                    .recording_state = .started,
                    .sample_number = self.getOffsetRecordingStart(self.start_sample.?),
                    .instant_silero_vad = vad,
                };
            }
        },
        .open => {
            // std.debug.print("{any} - {d:.2}\n", .{ self.status, vad });
            if (vad < cfg.off_threshold) {
                self.end_sample = last_sample_index;
                self.status = .closing;
            }
        },
        .closing => {
            const threshold_to_reopen = if (self.awaiting_close) cfg.off_threshold else cfg.on_threshold;

            if (vad >= threshold_to_reopen) {
                // speech resumed
                self.status = if (self.awaiting_close) .open else .opening;
                self.end_sample = null;
                return Result{
                    .recording_state = .none,
                    .sample_number = 0,
                    .instant_silero_vad = vad,
                };
            }

            // silence since last speech
            const silence_since_speech_samples_f: f32 = @floatFromInt(last_sample_index - self.end_sample.?);
            const samples_per_ms = @as(f32, @floatFromInt(in_sample_rate)) / 1000;
            const silence_duration_ms = 1000 * silence_since_speech_samples_f / samples_per_ms;

            if (silence_duration_ms >= cfg.max_silence_between_speech_ms) {
                const start_sample = self.start_sample.?;
                const end_sample = self.end_sample.?;
                self.start_sample = null;
                self.end_sample = null;
                self.status = .closed;

                if (self.awaiting_close) {
                    self.awaiting_close = false;

                    const segment = AudioPipeline.SpeechSegment{
                        .sample_from = self.getOffsetRecordingStart(start_sample),
                        .sample_to = self.getOffsetRecordingEnd(end_sample),
                        .detected_sample_from = start_sample,
                        .detected_sample_to = end_sample,
                        // TODO: Remove these?
                        .avg_channel_vol_ratio = 0,
                        .vad_met_sec = 0,
                    };
                    try self.vad_segments.append(self.allocator, segment);

                    return Result{
                        .recording_state = .completed,
                        .sample_number = self.getOffsetRecordingEnd(end_sample),
                        .instant_silero_vad = vad,
                    };
                } else {
                    // intentionally blank, VAD was "opening" but didn't meet the criteria
                }
            }
        },
    }

    return Result{
        .recording_state = .none,
        .sample_number = 0,
        .instant_silero_vad = vad,
    };
}

/// Add a couple of seconds of margin to the start of the segment
fn getOffsetRecordingStart(self: SileroVADMachine, vad_from: u64) u64 {
    const cfg = self.config;

    const sample_rate = self.sample_rate;
    const start_buffer: usize = sample_rate * cfg.pad_start_ms / 1000;
    // take care not to underflow unsigned values
    const record_from = vad_from - @min(start_buffer, vad_from);

    const sample_range = BufferedStep.convertSampleIndexToRoot2(self.root_sr_mul, record_from);
    return sample_range.from;
}

/// Add a couple of seconds of margin to the end of the segment
fn getOffsetRecordingEnd(self: SileroVADMachine, vad_to: u64) u64 {
    const cfg = self.config;

    const sample_rate = self.sample_rate;
    const end_buffer: usize = sample_rate * cfg.pad_end_ms / 1000;
    const record_to = vad_to + end_buffer;

    const sample_range = BufferedStep.convertSampleIndexToRoot2(self.root_sr_mul, record_to);
    return sample_range.to;
}

fn activationFn(off_before: f32, on_after: f32, value: f32) f32 {
    if (value < off_before) {
        return 0;
    } else if (value > on_after) {
        return 1;
    } else {
        const span = on_after - off_before;
        const offset_val = value - off_before;
        return offset_val / span;
    }
}

test "activationFn" {
    const t = std.testing;

    try t.expectApproxEqAbs(0, activationFn(1, 2, 1), 0.001);
    try t.expectApproxEqAbs(1, activationFn(1, 2, 2), 0.001);
    try t.expectApproxEqAbs(0.5, activationFn(1, 2, 1.5), 0.001);
    try t.expectApproxEqAbs(0.25, activationFn(1, 2, 1.25), 0.001);
    try t.expectApproxEqAbs(0.75, activationFn(1, 2, 1.75), 0.001);
}

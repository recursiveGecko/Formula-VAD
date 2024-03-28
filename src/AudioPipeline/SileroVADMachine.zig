const std = @import("std");
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

const on_threshold: f32 = 0.5;
const off_threshold: f32 = on_threshold - 0.15;
const min_speech_duration_ms: f32 = 800;
const max_silence_between_speech_ms: f32 = 1500;
const pad_start_ms: usize = 2000;
const pad_end_ms: usize = 2000;

allocator: std.mem.Allocator,
prev_step: *const BufferedStep,
vad_segments: std.ArrayList(AudioPipeline.SpeechSegment),
start_sample: ?usize = null,
end_sample: ?usize = null,
status: SpeechState = .closed,
/// whether speech is "active", according to our caller
awaiting_close: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    prev_step: *const BufferedStep,
) !SileroVADMachine {
    return SileroVADMachine{
        .allocator = allocator,
        .prev_step = prev_step,
        .vad_segments = std.ArrayList(AudioPipeline.SpeechSegment).init(allocator),
    };
}

pub fn deinit(self: *SileroVADMachine) void {
    self.vad_segments.deinit();
}

pub fn run(
    self: *SileroVADMachine,
    prev_result: *const BufferedStep.Result,
    fft_result: *const BufferedFFT.FFTResult,
) !Result {
    _ = fft_result; // autofix
    const first_sample_index = prev_result.segment.index;
    const last_sample_index = first_sample_index + prev_result.segment.length() - 1;
    std.debug.assert(prev_result.segment.nChannels() == 1);

    const in_sample_rate = self.prev_step.audio_config.out_sample_rate;
    const vad = prev_result.metadata.silero_vad.?;

    // std.debug.print("{d:5.3}\n", .{vad});

    switch (self.status) {
        .closed => {
            if (vad >= on_threshold) {
                // 1. Start opening sequence
                self.start_sample = first_sample_index;
                self.status = .opening;
            }
        },
        .opening => {
            const speech_duration_samples_f: f32 = @floatFromInt(last_sample_index - self.start_sample.?);
            const samples_per_ms = @as(f32, @floatFromInt(in_sample_rate)) / 1000;
            const speech_duration_ms = speech_duration_samples_f / samples_per_ms;

            // std.debug.print("{any} - {d:.2} - {d:.1}\n", .{ self.status, vad, speech_duration_ms });

            if (vad < on_threshold) {
                self.status = .closing;
                self.end_sample = last_sample_index;
            }

            if (speech_duration_ms >= min_speech_duration_ms) {
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
            if (vad < off_threshold) {
                self.end_sample = last_sample_index;
                self.status = .closing;
            }
        },
        .closing => {
            const threshold_to_reopen = if (self.awaiting_close) off_threshold else on_threshold;

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

            if (silence_duration_ms >= max_silence_between_speech_ms) {
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
                    _ = try self.vad_segments.append(segment);

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
pub fn getOffsetRecordingStart(self: SileroVADMachine, vad_from: u64) u64 {
    const sample_rate = self.prev_step.audio_config.out_sample_rate;
    const start_buffer: usize = sample_rate * pad_start_ms / 1000;
    // take care not to underflow unsigned values
    const record_from = vad_from - @min(start_buffer, vad_from);

    const sample_range = self.prev_step.convertSampleIndexToRoot(record_from);
    return sample_range.from;
}

/// Add a couple of seconds of margin to the end of the segment
pub fn getOffsetRecordingEnd(self: SileroVADMachine, vad_to: u64) u64 {
    const sample_rate = self.prev_step.audio_config.out_sample_rate;
    const end_buffer: usize = sample_rate * pad_end_ms / 1000;
    const record_to = vad_to + end_buffer;

    const sample_range = self.prev_step.convertSampleIndexToRoot(record_to);
    return sample_range.to;
}

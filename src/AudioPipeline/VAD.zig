const std = @import("std");
const log = std.log.scoped(.vad);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const PipelineFFT = @import("./PipelineFFT.zig");
const window_fn = @import("../audio_utils/window_fn.zig");
const AudioPipeline = @import("../AudioPipeline.zig");
const Denoiser = @import("../Denoiser.zig");
const FixedCapacityDeque = @import("../structures/FixedCapacityDeque.zig").FixedCapacityDeque;
const SplitSlice = @import("../structures/SplitSlice.zig").SplitSlice;
const Segment = @import("./Segment.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const RollingAverage = @import("../structures/RollingAverage.zig");
const DirtyMemPool = @import("../structures/DirtyMemPool.zig").DirtyMemPool;

const Self = @This();

pub const Config = struct {
    fft_size: usize = 2048,
    initial_long_term_avg: ?f64 = 0.005,
    long_term_average_sec: f32 = 180,
    short_term_average_sec: f32 = 0.2,
    speech_min_freq: f32 = 100,
    speech_max_freq: f32 = 1500,
    speech_threshold_factor: f32 = 22,
    min_consecutive_ms_to_open: f32 = 200,
    max_speech_gap_ms: f32 = 1000,
    min_vad_duration_ms: f32 = 700,
};

pub const VADSegment = struct {
    sample_from: usize,
    sample_to: usize,
    debug_rnn_vad: f32,
    debug_avg_speech_vol_ratio: f32,
};

const DenoiserResult = struct {
    index: u64,
    length: usize,
    segment: Segment,
    vad: f32,

    pub fn init(allocator: Allocator, n_channels: usize) !@This() {
        const segment_length = Denoiser.getFrameSize();
        var segment = try Segment.initWithCapacity(allocator, n_channels, segment_length);

        return @This(){
            .segment = segment,
            .length = segment_length,
            .index = undefined,
            .vad = undefined,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.segment.deinit();
    }
};

const SpeechState = enum {
    closed,
    opening,
    open,
    closing,
};

allocator: Allocator,
pipeline: *AudioPipeline,
config: Config,
n_channels: usize,
// Number of samples that have been fully processed and won't be needed anymore
fully_processed_count: u64 = 0,
/// Holds Denoiser/RNNoise state
denoiser: Denoiser,
/// Number of samples denoiser step has read from the pipeline
denoiser_read_count: u64 = 0,
/// Stores a temporary slice of the pipeline that is being denoised
denoiser_input_segment: Segment,
/// Queue containing denoised audio segments
denoiser_result_queue: FixedCapacityDeque(*DenoiserResult),
/// Pool of results
denoiser_result_pool: DirtyMemPool(DenoiserResult, usize, DenoiserResult.init),
/// Buffer between denoiser and FFT, forming segments that are
/// `fft_size` samples long
denoiser_fft_buffer: SegmentWriter,
/// Stores RNNoise VAD for segments that are being buffered for FFT
fft_buffer_rnn_vad: f32 = 0,
/// FFT wrapper for the pipeline that holds the FFT state,
/// our chosen window function, and that can process multiple
/// channels of audio data at once (operating on Segments)
pipeline_fft: PipelineFFT,
/// Temporarily stores the FFT result
pipeline_fft_result: PipelineFFT.Result,
// Speech state machine
speech_state: SpeechState = .closed,
long_term_speech_volume: RollingAverage,
short_term_speech_volume: RollingAverage,
audio_vol_ratio: RollingAverage,
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
vad_segments: std.ArrayList(VADSegment),

pub fn init(pipeline: *AudioPipeline, config: Config) !Self {
    const sample_rate = pipeline.config.sample_rate;
    const n_channels = pipeline.config.n_channels;

    if (sample_rate != 48000) {
        // RNNoise can only handle 48kHz audio
        return error.InvalidSampleRate;
    }

    var allocator = pipeline.allocator;

    var denoiser = try Denoiser.init(allocator);
    errdefer denoiser.deinit();

    var denoiser_input_segment = Segment{
        .channel_pcm_buf = try allocator.alloc(SplitSlice(f32), n_channels),
        .allocator = allocator,
        .index = undefined,
        .length = undefined,
    };
    errdefer denoiser_input_segment.deinit();

    // TODO: Find optimal length?
    var denoiser_res_queue = try FixedCapacityDeque(*DenoiserResult).init(allocator, 100);
    errdefer denoiser_res_queue.deinit();

    var denoiser_result_pool = try DirtyMemPool(
        DenoiserResult,
        usize,
        DenoiserResult.init,
    ).init(allocator, n_channels);
    errdefer denoiser_result_pool.deinit();

    var denoiser_fft_buffer = try SegmentWriter.init(allocator, n_channels, config.fft_size);
    // Pipeline sample number that corresponds to the start of the FFT buffer
    denoiser_fft_buffer.segment.index = 0;
    errdefer denoiser_fft_buffer.deinit();

    var pipeline_fft = try PipelineFFT.init(allocator, .{
        .n_channels = n_channels,
        .fft_size = config.fft_size,
        .hop_size = config.fft_size,
        .sample_rate = sample_rate,
    });
    errdefer pipeline_fft.deinit();

    var pipeline_fft_result = try PipelineFFT.Result.init(
        allocator,
        n_channels,
        config.fft_size,
        pipeline_fft.fft_instance.binCount(),
    );
    errdefer pipeline_fft_result.deinit();

    const eval_per_sec = sample_rate / config.fft_size;
    const long_term_avg_len = @floatToInt(
        usize,
        @intToFloat(f32, eval_per_sec) * config.long_term_average_sec,
    );
    const short_term_avg_len = @floatToInt(
        usize,
        @intToFloat(f32, eval_per_sec) * config.short_term_average_sec,
    );

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

    var audio_vol_ratio = try RollingAverage.init(
        allocator,
        5,
        null,
    );
    errdefer audio_vol_ratio.deinit();

    const temp_channel_volumes = try allocator.alloc(f32, n_channels);
    errdefer allocator.free(temp_channel_volumes);

    var vad_segments = try std.ArrayList(VADSegment).initCapacity(allocator, 100);
    errdefer vad_segments.deinit();

    var self = Self{
        .allocator = allocator,
        .pipeline = pipeline,
        .config = config,
        .n_channels = n_channels,
        .denoiser = denoiser,
        .denoiser_input_segment = denoiser_input_segment,
        .denoiser_result_queue = denoiser_res_queue,
        .denoiser_result_pool = denoiser_result_pool,
        .denoiser_fft_buffer = denoiser_fft_buffer,
        .pipeline_fft = pipeline_fft,
        .pipeline_fft_result = pipeline_fft_result,
        .long_term_speech_volume = long_term_speech_avg,
        .short_term_speech_volume = short_term_speech_avg,
        .audio_vol_ratio = audio_vol_ratio,
        .temp_channel_volumes = temp_channel_volumes,
        .vad_segments = vad_segments,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    while (self.denoiser_result_queue.length() > 0) {
        var r = self.denoiser_result_queue.popFront() catch unreachable;
        r.deinit();
    }
    self.denoiser_input_segment.deinit();
    self.denoiser.deinit();
    self.denoiser_result_queue.deinit();
    self.denoiser_result_pool.deinit();
    self.denoiser_fft_buffer.deinit();
    self.pipeline_fft.deinit();
    self.pipeline_fft_result.deinit();

    self.long_term_speech_volume.deinit();
    self.short_term_speech_volume.deinit();
    self.audio_vol_ratio.deinit();
    self.vad_segments.deinit();
}

pub fn run(self: *Self) !void {
    var keep_running: bool = true;

    // Keep running as long as there is data to process
    while (keep_running) {
        const s1 = try self.denoiserStep();
        const s2 = try self.denoiserFftBufferStep();

        keep_running = s1 or s2;
    }
}

/// Returns true if any processing was done
fn denoiserStep(self: *Self) !bool {
    const frame_size = Denoiser.getFrameSize();
    const p = self.pipeline;

    // While there are enough input samples to form a RNNoise frame
    while (p.total_write_count - self.denoiser_read_count >= frame_size) {
        if (self.denoiser_result_queue.remainingCapacity() == 0) return true;

        const from = self.denoiser_read_count;
        const to = from + frame_size;

        try self.pipeline.sliceSegment(&self.denoiser_input_segment, from, to);
        var input_segment: *Segment = &self.denoiser_input_segment;

        var denoiser_result: *DenoiserResult = try self.denoiser_result_pool.acquire();
        var denoised_segment: *Segment = &denoiser_result.segment;

        // We will use the lowest RNNoise VAD of all channels
        var vad_low: f32 = 1;
        const n_channels = input_segment.channel_pcm_buf.len;
        for (0..n_channels) |channel_idx| {
            var channel_pcm = input_segment.channel_pcm_buf[channel_idx];
            var result_pcm = denoised_segment.channel_pcm_buf[channel_idx].first;

            const vad = try self.denoiser.denoise(channel_pcm, @constCast(result_pcm));
            if (vad < vad_low) vad_low = vad;
        }

        denoised_segment.index = from;
        denoiser_result.index = from;
        denoiser_result.length = frame_size;
        denoiser_result.vad = vad_low;

        try self.denoiser_result_queue.pushBack(denoiser_result);
        self.denoiser_read_count = to;
    }

    return false;
}

fn denoiserFftBufferStep(self: *Self) !bool {
    var fft_buffer = &self.denoiser_fft_buffer;
    const fft_buffer_len = fft_buffer.segment.length;

    while (self.denoiser_result_queue.length() > 0) {
        var denoiser_result: *DenoiserResult = try self.denoiser_result_queue.popFront();
        defer self.denoiser_result_pool.release(denoiser_result);

        // Denoiser segment could be larger than the FFT buffer (depending on FFT size)
        // So we might have to split it into multiple FFT buffer writes
        const denoised_segment: *const Segment = &denoiser_result.segment;
        var denoised_buf_offset: usize = 0;

        while (true) {
            const written = try fft_buffer.write(denoised_segment.*, denoised_buf_offset);
            denoised_buf_offset += written;
            std.debug.assert(denoised_buf_offset <= denoised_segment.length);

            const fft_buffer_is_full = fft_buffer.write_index == fft_buffer_len;

            // Keep track of the average RNNoise VAD value for the samples
            // going into the FFT buffer
            const current_segment_share = @intToFloat(f32, written) / @intToFloat(f32, fft_buffer_len);
            self.fft_buffer_rnn_vad += denoiser_result.vad * current_segment_share;

            if (fft_buffer_is_full) {
                var fft_input = DenoiserResult{
                    .index = fft_buffer.segment.index,
                    .length = fft_buffer.segment.length,
                    .segment = fft_buffer.segment,
                    .vad = self.fft_buffer_rnn_vad,
                };

                try self.fftStep(&fft_input);

                // Global index of the first sample in the next segment
                const next_fft_buffer_index = denoised_segment.index + denoised_buf_offset;
                fft_buffer.reset(next_fft_buffer_index);
                self.fft_buffer_rnn_vad = 0;
            }

            // We have written the entirety of the source segment
            if (denoised_buf_offset == denoised_segment.length) {
                break;
            }
        }
    }

    return false;
}

fn fftStep(self: *Self, fft_input: *DenoiserResult) !void {
    try self.pipeline_fft.fft(fft_input.segment, &self.pipeline_fft_result);
    try self.speechStep(&self.pipeline_fft_result, fft_input.vad);
}

fn speechStep(self: *Self, result: *PipelineFFT.Result, rnn_vad: f32) !void {
    const sample_rate = self.pipeline.config.sample_rate;
    const sample_rate_f = @intToFloat(f32, sample_rate);
    const config = self.config;

    // Find the average volume in the speech band
    try self.pipeline_fft.averageVolumeInBand(
        result.*,
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
    const speech_ratio = min_volume / max_volume;

    // Number of consecutive samples above the threshold before the VAD opens
    const min_consecutive_to_open = @floatToInt(usize, sample_rate_f * config.min_consecutive_ms_to_open / 1000);
    // Number of consecutive samples below the threshold before the VAD closes
    const max_gap_samples = @floatToInt(usize, sample_rate_f * config.max_speech_gap_ms / 1000);

    // Use the minimum for activation as it's likely the one containing less engine noise, and therefore more accurate
    const short_term = self.short_term_speech_volume.push(min_volume);

    const threshold_base = self.long_term_speech_volume.last_avg orelse config.initial_long_term_avg orelse short_term;
    const threshold = threshold_base * config.speech_threshold_factor;
    const threshold_met = short_term > threshold;

    // Do not update the long term average if the threshold is met
    // TODO: This is problematic, if the threshold happens to be set too low, it would cause
    // continuous VAD activation which would prevent self-correction
    if (!threshold_met) {
        _ = self.long_term_speech_volume.push(min_volume);
    }

    // Speech state machine
    switch (self.speech_state) {
        .closed => {
            if (threshold_met) {
                self.speech_state = .opening;
                self.speech_start_index = result.index;
            }

            self.trackSpeechStats(rnn_vad, speech_ratio, .closed, self.speech_state);
        },
        .opening => {
            const samples_since_opening = result.index - self.speech_start_index;
            const opening_duration_met = samples_since_opening >= min_consecutive_to_open;

            if (threshold_met and opening_duration_met) {
                self.speech_state = .open;
                try self.onSpeechStart();
            } else if (!threshold_met) {
                self.speech_state = .closed;
            }

            self.trackSpeechStats(rnn_vad, speech_ratio, .opening, self.speech_state);
        },
        .open => {
            if (!threshold_met) {
                self.speech_state = .closing;
                self.speech_end_index = result.index + config.fft_size;
            }

            self.trackSpeechStats(rnn_vad, speech_ratio, .open, self.speech_state);
        },
        .closing => {
            const samples_since_closing = result.index - self.speech_end_index;
            const closing_duration_met = samples_since_closing >= max_gap_samples;

            if (threshold_met) {
                self.speech_state = .open;
            } else if (closing_duration_met) {
                self.speech_state = .closed;
                try self.onSpeechEnd();
            }

            self.trackSpeechStats(rnn_vad, speech_ratio, .closing, self.speech_state);
        },
    }

    if (self.speech_state == .open or self.speech_state == .closed) {
        self.fully_processed_count = result.index;
    }

    log.debug(
        "Speech threshold: {d: >10.5} Loudness: {d: >10.5}   Threshold: {any: >6}   Status: {s: >9}",
        .{ threshold * 100, short_term * 100, threshold_met, @tagName(self.speech_state) },
    );
}

/// Track RNNoise's own VAD score during speech segments
fn trackSpeechStats(self: *Self, rnn_vad: f32, speech_ratio: f32, from_state: SpeechState, to_state: SpeechState) void {
    if (from_state == .closed and to_state == .opening) {
        self.speech_rnn_vad = rnn_vad;
        self.speech_rnn_vad_count = 1;
        self.speech_vol_ratio = speech_ratio;
        self.speech_vol_ratio_count = 1;
    } else if (from_state == .opening or from_state == .open) {
        self.speech_rnn_vad += rnn_vad;
        self.speech_rnn_vad_count += 1;
        self.speech_vol_ratio += speech_ratio;
        self.speech_vol_ratio_count += 1;
    }
}

fn onSpeechStart(self: *Self) !void {
    try self.pipeline.beginCapture(self.speech_start_index);
}

fn onSpeechEnd(self: *Self) !void {
    const sample_from = self.speech_start_index;
    const sample_to = self.speech_end_index;
    const length_samples = sample_to - sample_from;

    const sample_rate = self.pipeline.config.sample_rate;
    const sample_rate_f = @intToFloat(f32, sample_rate);
    const config = self.config;

    const length_realtime = @intToFloat(f32, length_samples) / sample_rate_f;
    const speech_duration_met = length_realtime * 1000 >= config.min_vad_duration_ms;

    const avg_rnn_vad = self.speech_rnn_vad / @intToFloat(f32, self.speech_rnn_vad_count);
    const avg_speech_vol_ratio = self.speech_vol_ratio / @intToFloat(f32, self.speech_vol_ratio_count);

    if (speech_duration_met) {
        const segment = VADSegment{
            .sample_from = sample_from,
            .sample_to = sample_to,
            .debug_rnn_vad = avg_rnn_vad,
            .debug_avg_speech_vol_ratio = avg_speech_vol_ratio,
        };
        _ = try self.vad_segments.append(segment);

        const debug_len_s = @intToFloat(f32, length_samples) / sample_rate_f;

        log.info(
            "VAD Segment: {d: >6.2}s  | Avg. RNNoise VAD: {d: >6.2}% | Avg. vol ratio: {d: >5.2} ",
            .{ debug_len_s, avg_rnn_vad * 100, avg_speech_vol_ratio },
        );
    }

    try self.pipeline.endCapture(self.speech_start_index, speech_duration_met);
}

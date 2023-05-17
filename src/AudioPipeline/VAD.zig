const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const PipelineFFT = @import("./PipelineFFT.zig");
const window_fn = @import("../audio_utils/window_fn.zig");
const AudioPipeline = @import("../AudioPipeline.zig");
const Denoiser = @import("../Denoiser.zig");
const FixedCapacityDeque = @import("../structures/FixedCapacityDeque.zig").FixedCapacityDeque;
const SplitSlice = @import("../structures/SplitSlice.zig");
const Segment = @import("./Segment.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const RollingAverage = @import("../structures/RollingAverage.zig");

const Self = @This();

pub const Config = struct {
    fft_size: usize = 2048,
    initial_long_term_avg: ?f64 = 0.005,
    long_term_average_sec: f32 = 180,
    short_term_average_sec: f32 = 0.2,
    speech_min_freq: f32 = 100,
    speech_max_freq: f32 = 1500,
    speech_threshold_factor: f32 = 10,
    min_consecutive_ms_to_open: f32 = 200,
    max_speech_gap_ms: f32 = 1000,
    min_vad_duration_ms: f32 = 700,
};

pub const VADSegment = struct {
    sample_from: usize,
    sample_to: usize,
};

const DenoiserResult = struct {
    index: u64,
    length: usize,
    segment: Segment,
    vad: f32,

    pub fn deinit(self: *@This()) void {
        self.segment.deinit();
    }
};

allocator: Allocator,
pipeline: *AudioPipeline,
config: Config,
n_channels: usize,
/// Holds Denoiser/RNNoise state
denoiser: Denoiser,
/// Number of samples that denoiser step has read from the pipeline
denoiser_read_count: u64 = 0,
/// Queue containing denoised audio segments
denoiser_result_queue: FixedCapacityDeque(DenoiserResult),
/// Buffer between denoiser and FFT, forming segments that are
/// `fft_size` samples long
denoiser_fft_buffer: SegmentWriter,
// Holds Segments that are ready to be processed by FFT
fft_input_queue: FixedCapacityDeque(Segment),
/// FFT wrapper for the pipeline that holds the FFT state,
/// our chosen window function, and that can process multiple
/// channels of audio data at once (operating on Segments)
pipeline_fft: PipelineFFT,
// Speech state machine
long_term_speech_volume: RollingAverage,
short_term_speech_volume: RollingAverage,
speech_start_index: u64 = 0,
speech_end_index: u64 = 0,
speech_state: enum {
    closed,
    opening,
    open,
    closing,
} = .closed,
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

    // TODO: Find optimal length?
    var denoiser_res_queue = try FixedCapacityDeque(DenoiserResult).init(allocator, 20);
    errdefer denoiser_res_queue.deinit();

    var denoiser_fft_buffer = try SegmentWriter.init(allocator, n_channels, config.fft_size);
    // Pipeline sample number that corresponds to the start of the FFT buffer
    denoiser_fft_buffer.segment.index = 0;
    errdefer denoiser_fft_buffer.deinit();

    // TODO: Find optimal length?
    var fft_input_queue = try FixedCapacityDeque(Segment).init(allocator, 20);
    errdefer fft_input_queue.deinit();

    var pipeline_fft = try PipelineFFT.init(allocator, .{
        .n_channels = n_channels,
        .fft_size = config.fft_size,
        .hop_size = config.fft_size,
        .sample_rate = sample_rate,
    });
    errdefer pipeline_fft.deinit();

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

    var vad_segments = try std.ArrayList(VADSegment).initCapacity(allocator, 100);
    errdefer vad_segments.deinit();

    var self = Self{
        .allocator = allocator,
        .pipeline = pipeline,
        .config = config,
        .n_channels = n_channels,
        .denoiser = denoiser,
        .denoiser_result_queue = denoiser_res_queue,
        .denoiser_fft_buffer = denoiser_fft_buffer,
        .fft_input_queue = fft_input_queue,
        .pipeline_fft = pipeline_fft,
        .long_term_speech_volume = long_term_speech_avg,
        .short_term_speech_volume = short_term_speech_avg,
        .vad_segments = vad_segments,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    while (self.denoiser_result_queue.length() > 0) {
        var r = self.denoiser_result_queue.popFront() catch unreachable;
        r.deinit();
    }
    while (self.fft_input_queue.length() > 0) {
        var r = self.fft_input_queue.popFront() catch unreachable;
        r.deinit();
    }
    self.denoiser.deinit();
    self.denoiser_result_queue.deinit();
    self.denoiser_fft_buffer.deinit();
    self.pipeline_fft.deinit();
    self.fft_input_queue.deinit();

    self.long_term_speech_volume.deinit();
    self.short_term_speech_volume.deinit();
    self.vad_segments.deinit();
}

pub fn run(self: *Self) !void {
    try self.denoiserStep();
    try self.denoiserFftBufferStep();
    try self.fftStep();
}

fn denoiserStep(self: *Self) !void {
    const frame_size = Denoiser.getFrameSize();
    const p = self.pipeline;

    // While there are enough input samples to form a RNNoise frame
    while (p.total_write_count - self.denoiser_read_count >= frame_size) {
        const from = self.denoiser_read_count;
        const to = from + frame_size;

        var segment = try self.pipeline.sliceSegment(from, to);
        defer segment.deinit();

        // Create a segment that can hold the denoised result
        var result_segment = try segment.copyCapacity(self.allocator);
        errdefer result_segment.deinit();

        // We will use the lowest RNNoise VAD of all channels
        var vad_low: f32 = 1;
        const n_channels = segment.channel_pcm_buf.len;
        for (0..n_channels) |channel_idx| {
            var channel_pcm = segment.channel_pcm_buf[channel_idx];
            var result_pcm = result_segment.channel_pcm_buf[channel_idx].first;

            const vad = try self.denoiser.denoise(channel_pcm, @constCast(result_pcm));
            if (vad < vad_low) vad_low = vad;
        }

        var denoise_result = DenoiserResult{
            .index = from,
            .length = frame_size,
            .segment = result_segment,
            .vad = vad_low,
        };

        try self.denoiser_result_queue.pushBack(denoise_result);
        self.denoiser_read_count = to;
    }
}

fn denoiserFftBufferStep(self: *Self) !void {
    while (self.denoiser_result_queue.length() > 0) {
        var denoiser_result = try self.denoiser_result_queue.popFront();
        defer denoiser_result.deinit();

        var segment: Segment = denoiser_result.segment;

        // Denoiser segment could be larger than the FFT buffer (depending on FFT size)
        // So we might have to process it in multiple steps
        var offset: usize = 0;
        while (true) {
            const written = try self.denoiser_fft_buffer.write(segment, offset);
            // Number of samples remaining in the source segment
            const source_remaining = segment.length - offset - written;
            // Number of samples that we expected to write to the FFT buffer
            const expected_to_write = segment.length - offset;
            const buffer_is_full = written != expected_to_write;

            if (buffer_is_full) {
                var fft_segment = self.denoiser_fft_buffer.segment;
                var segment_copy = try fft_segment.copy(self.allocator);
                errdefer segment_copy.deinit();

                // TODO: We could avoid this queue and just run the FFT directly
                try self.fft_input_queue.pushBack(segment_copy);
                offset += written;

                // Global index of the first sample in the next segment
                const next_segment_index = segment.index + offset;
                self.denoiser_fft_buffer.reset(next_segment_index);
            }

            // We have written all of the source segment
            if (source_remaining == 0) {
                break;
            }
        }
    }
}

fn fftStep(self: *Self) !void {
    while (self.fft_input_queue.length() > 0) {
        var fft_in_segment: Segment = try self.fft_input_queue.popFront();
        defer fft_in_segment.deinit();

        var result: PipelineFFT.Result = try self.pipeline_fft.fft(fft_in_segment);
        defer result.deinit();

        // std.debug.print("FFT input segment: {d}\n", .{fft_in_segment.index / self.pipeline.config.sample_rate});

        try self.speechStep(result);
    }
}

fn speechStep(self: *Self, result: PipelineFFT.Result) !void {
    const sample_rate = self.pipeline.config.sample_rate;
    const sample_rate_f = @intToFloat(f32, sample_rate);
    const config = self.config;

    // Find the average volume in the speech band
    const channel_volume = try self.allocator.alloc(f32, self.n_channels);
    defer self.allocator.free(channel_volume);
    try self.pipeline_fft.averageVolumeInBand(result, config.speech_min_freq, config.speech_max_freq, channel_volume);

    // Take the minimum of all channels as it's likely the one containing less engine noise, and therefore more accurate
    var min_volume: f32 = 999;
    for (channel_volume) |loudness| {
        if (loudness < min_volume) min_volume = loudness;
    }

    // std.debug.print("Speech loudness: {d: >10.5} \n", .{short_term * 100});

    // Number of consecutive samples above the threshold before the VAD opens
    const min_consecutive_to_open = @floatToInt(usize, sample_rate_f * config.min_consecutive_ms_to_open / 1000);
    // Number of consecutive samples below the threshold before the VAD closes
    const max_gap_samples = @floatToInt(usize, sample_rate_f * config.max_speech_gap_ms / 1000);

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
        },
        .opening => {
            const samples_since_opening = result.index - self.speech_start_index;
            const opening_duration_met = samples_since_opening >= min_consecutive_to_open;

            if (threshold_met and opening_duration_met) {
                self.speech_state = .open;
                // std.debug.print("Mic open.\n", .{});
            } else if (!threshold_met) {
                self.speech_state = .closed;
            }
        },
        .open => {
            if (!threshold_met) {
                self.speech_state = .closing;
                self.speech_end_index = result.index + config.fft_size;
            }
        },
        .closing => {
            const samples_since_closing = result.index - self.speech_end_index;
            const closing_duration_met = samples_since_closing >= max_gap_samples;

            if (threshold_met) {
                self.speech_state = .open;
            } else if (closing_duration_met) {
                self.speech_state = .closed;
                // std.debug.print("Mic closed.\n", .{});
                try self.handleSpeechEvent();
            }
        },
    }

    // std.debug.print(
    //     "Speech threshold: {d: >10.5} Loudness: {d: >10.5}   Threshold: {any: >6}   Status: {s: >9}\n",
    //     .{ threshold * 100, short_term * 100, threshold_met, @tagName(self.speech_state) },
    // );
}

fn handleSpeechEvent(self: *Self) !void {
    const sample_from = self.speech_start_index;
    const sample_to = self.speech_end_index;
    const length_samples = sample_to - sample_from;

    const sample_rate = self.pipeline.config.sample_rate;
    const sample_rate_f = @intToFloat(f32, sample_rate);
    const config = self.config;

    const length_realtime = @intToFloat(f32, length_samples) / sample_rate_f;
    const speech_duration_met = length_realtime * 1000 >= config.min_vad_duration_ms;

    // std.debug.print("Speech duration: {d: >6.2}", .{length_realtime});

    if (speech_duration_met) {
        const segment = VADSegment{
            .sample_from = sample_from,
            .sample_to = sample_to,
        };
        _ = try self.vad_segments.append(segment);

        // std.debug.print(" (ok)\n", .{});
    } else {
        // Discard, VAD too short
        // std.debug.print(" (too short)\n", .{});
    }
}

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
// 1. Denoiser step
denoiser: Denoiser,
denoiser_read_count: u64 = 0,
denoiser_result_queue: FixedCapacityDeque(DenoiserResult),
// 2. Buffer between denoiser and FFT
denoiser_fft_buffer: SegmentWriter,
// 3. FFT step
pipeline_fft: PipelineFFT,
// Holds Segments that are ready to be processed by FFT
fft_input_queue: FixedCapacityDeque(Segment),
// 4. Post-processing
long_term_speech_loudness: RollingAverage,
short_term_speech_loudness: RollingAverage,

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
        .sample_rate = sample_rate,
    });
    errdefer pipeline_fft.deinit();

    const eval_per_sec = sample_rate / config.fft_size;
    var long_term_speech_avg = try RollingAverage.init(allocator, eval_per_sec * 120);
    errdefer long_term_speech_avg.deinit();

    var short_term_speech_avg = try RollingAverage.init(allocator, eval_per_sec / 2);
    errdefer short_term_speech_avg.deinit();

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
        .long_term_speech_loudness = long_term_speech_avg,
        .short_term_speech_loudness = short_term_speech_avg,
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

    self.long_term_speech_loudness.deinit();
    self.short_term_speech_loudness.deinit();
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

        const channel_loudness = try self.allocator.alloc(f32, self.n_channels);
        defer self.allocator.free(channel_loudness);

        try self.pipeline_fft.averageLoudnessInBand(result, 100, 1500, channel_loudness);

        var min_loudness: f32 = 1;
        for (channel_loudness) |loudness| {
            if (loudness < min_loudness) min_loudness = loudness;
        }

        const long_term = self.long_term_speech_loudness.push(min_loudness);
        _ = long_term;
        const short_term = self.short_term_speech_loudness.push(min_loudness);

        std.debug.print("Speech loudness: {d: >10.5} \n", .{ short_term * 100 });
    }
}

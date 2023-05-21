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
const VADMachine = @import("./VADMachine.zig");
const audio_utils = @import("../audio_utils.zig");

const Self = @This();

pub const Config = struct {
    fft_size: usize = 2048,
    vad_machine_config: VADMachine.Config = .{},
    // Alternative state machine configs for training
    alt_vad_machine_config: ?[]VADMachine.Config = null,
};

pub const VADSegment = struct {
    sample_from: usize,
    sample_to: usize,
    debug_rnn_vad: f32,
    debug_avg_speech_vol_ratio: f32,
};

pub const RecordingState = enum {
    none,
    started,
    completed,
    aborted,
};

pub const VADMachineResult = struct {
    recording_state: RecordingState,
    sample_number: u64,
};

pub const DenoiserResult = struct {
    index: u64,
    length: usize,
    segment: Segment,
    vad: f32,
    volume_ratio: f32,

    pub fn init(allocator: Allocator, n_channels: usize) !@This() {
        const segment_length = Denoiser.getFrameSize();
        var segment = try Segment.initWithCapacity(allocator, n_channels, segment_length);

        return @This(){
            .segment = segment,
            .length = segment_length,
            .index = undefined,
            .vad = undefined,
            .volume_ratio = undefined,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.segment.deinit();
    }
};

allocator: Allocator,
pipeline: *AudioPipeline,
config: Config,
sample_rate: usize,
n_channels: usize,
/// Holds Denoiser/RNNoise state
denoiser: Denoiser,
/// Number of samples denoiser step has read from the pipeline
denoiser_read_count: u64 = 0,
/// Stores a temporary slice of the pipeline that is being denoised
temp_denoiser_input_segment: Segment,
/// Stores the temporary result of the denoiser step
temp_denoiser_result: DenoiserResult,
/// Buffer between denoiser and FFT, forming segments that are
/// `fft_size` samples long
denoiser_fft_buffer: SegmentWriter,
/// Stores RNNoise VAD for segments that are being buffered for FFT
fft_buffer_rnn_vad: f32 = 0,
fft_buffer_vol_ratio: f32 = 0,
/// FFT wrapper for the pipeline that holds the FFT state,
/// our chosen window function, and that can process multiple
/// channels of audio data at once (operating on Segments)
pipeline_fft: PipelineFFT,
/// Temporarily stores the FFT result
temp_pipeline_fft_result: PipelineFFT.Result,
// Speech state machine
vad_machine: VADMachine,

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

    var temp_denoiser_input_segment = Segment{
        .channel_pcm_buf = try allocator.alloc(SplitSlice(f32), n_channels),
        .allocator = allocator,
        .index = undefined,
        .length = undefined,
    };
    errdefer temp_denoiser_input_segment.deinit();

    var temp_denoiser_result = try DenoiserResult.init(allocator, n_channels);
    errdefer temp_denoiser_result.deinit();

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

    var temp_pipeline_fft_result = try PipelineFFT.Result.init(
        allocator,
        n_channels,
        config.fft_size,
        pipeline_fft.fft_instance.binCount(),
    );
    errdefer temp_pipeline_fft_result.deinit();

    var self = Self{
        .allocator = allocator,
        .pipeline = pipeline,
        .config = config,
        .n_channels = n_channels,
        .sample_rate = sample_rate,
        .denoiser = denoiser,
        .temp_denoiser_input_segment = temp_denoiser_input_segment,
        .temp_denoiser_result = temp_denoiser_result,
        .denoiser_fft_buffer = denoiser_fft_buffer,
        .pipeline_fft = pipeline_fft,
        .temp_pipeline_fft_result = temp_pipeline_fft_result,
        .vad_machine = undefined,
    };

    self.vad_machine = try VADMachine.init(allocator, config.vad_machine_config, self);

    return self;
}

pub fn deinit(self: *Self) void {
    self.vad_machine.deinit();
    self.denoiser.deinit();
    self.temp_denoiser_input_segment.deinit();
    self.temp_denoiser_result.deinit();
    self.denoiser_fft_buffer.deinit();
    self.pipeline_fft.deinit();
    self.temp_pipeline_fft_result.deinit();
}

pub fn run(self: *Self) !void {
    try self.denoiserStep();
}

fn denoiserStep(self: *Self) !void {
    const frame_size = Denoiser.getFrameSize();
    const p = self.pipeline;

    // While there are enough input samples to form a RNNoise frame
    while (p.total_write_count - self.denoiser_read_count >= frame_size) {
        const from = self.denoiser_read_count;
        const to = from + frame_size;

        var input_segment: *Segment = &self.temp_denoiser_input_segment;
        try self.pipeline.sliceSegment(input_segment, from, to);
        const n_channels = input_segment.channel_pcm_buf.len;

        // Find the volume ratio between channels
        var vol_min: f32 = 1;
        var vol_max: f32 = 0;
        for (0..n_channels) |channel_idx| {
            var channel_slice = input_segment.channel_pcm_buf[channel_idx];
            var vol = audio_utils.rmsVolume(channel_slice);

            if (vol < vol_min) vol_min = vol;
            if (vol > vol_max) vol_max = vol;
        }

        var denoiser_result: *DenoiserResult = &self.temp_denoiser_result;
        var denoised_segment: *Segment = &denoiser_result.segment;

        // We will use the lowest RNNoise VAD of all channels
        var vad_low: f32 = 1;
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
        denoiser_result.volume_ratio = if (vol_max == 0) 0 else vol_min / vol_max;

        self.denoiser_read_count = to;

        _ = try self.denoiserFftBufferStep(denoiser_result);
    }
}

fn denoiserFftBufferStep(self: *Self, denoiser_result: *const DenoiserResult) !void {
    var fft_buffer = &self.denoiser_fft_buffer;
    const fft_buffer_len = fft_buffer.segment.length;

    const denoised_segment: *const Segment = &denoiser_result.segment;

    // Denoiser segment could be larger than the FFT buffer (depending on FFT size)
    // So we might have to split it into multiple FFT buffer writes
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
        self.fft_buffer_vol_ratio += denoiser_result.volume_ratio * current_segment_share;

        if (fft_buffer_is_full) {
            var fft_input = DenoiserResult{
                .index = fft_buffer.segment.index,
                .length = fft_buffer.segment.length,
                .segment = fft_buffer.segment,
                .vad = self.fft_buffer_rnn_vad,
                .volume_ratio = self.fft_buffer_vol_ratio,
            };

            try self.fftStep(&fft_input);

            // Global index of the first sample in the next segment
            const next_fft_buffer_index = denoised_segment.index + denoised_buf_offset;
            fft_buffer.reset(next_fft_buffer_index);
            self.fft_buffer_rnn_vad = 0;
            self.fft_buffer_vol_ratio = 0;
        }

        // We have written the entirety of the source segment
        if (denoised_buf_offset == denoised_segment.length) {
            break;
        }
    }
}

fn fftStep(self: *Self, fft_input: *DenoiserResult) !void {
    try self.pipeline_fft.fft(fft_input.segment, &self.temp_pipeline_fft_result);

    const vad_result = try self.vad_machine.run(fft_input.*, self.temp_pipeline_fft_result);

    switch (vad_result.recording_state) {
        .started => {
            try self.pipeline.beginCapture(vad_result.sample_number);
        },
        .completed => {
            try self.pipeline.endCapture(vad_result.sample_number, true);
        },
        .aborted => {
            try self.pipeline.endCapture(vad_result.sample_number, false);
        },
        .none => {},
    }
}

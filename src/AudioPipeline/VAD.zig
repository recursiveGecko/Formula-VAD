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
    use_denoiser: bool = true,
    vad_machine_config: VADMachine.Config = .{},
    // Alternative state machine configs for training
    alt_vad_machine_configs: ?[]VADMachine.Config = null,
};

pub const VADSpeechSegment = struct {
    sample_from: usize,
    sample_to: usize,
    debug_rnn_vad: f32,
    debug_avg_speech_vol_ratio: f32,
};

pub const VADMachineResult = struct {
    pub const RecordingState = enum {
        none,
        started,
        completed,
        aborted,
    };

    recording_state: RecordingState,
    sample_number: u64,
};

pub const AnalyzedSegment = struct {
    input_segment: ?*const Segment = null,
    segment: Segment,
    vad: ?f32 = null,
    volume_ratio: f32,

    pub fn init(allocator: Allocator, length: usize, n_channels: usize) !@This() {
        var segment = try Segment.initWithCapacity(allocator, n_channels, length);

        return @This(){
            .segment = segment,
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
/// Number of samples VAD has read from the pipeline
pipeline_read_count: u64 = 0,
/// Stores a temporary slice (pointer) of the pipeline that's ready for preprocessing
temp_input_segment: Segment,
/// Stores an audio segment with metadata that is being preprocessed (e.g. denoised)
temp_denoiser_segment: AnalyzedSegment,
/// Buffer in front of FFT step, forming segments that are `fft_size` samples long
fft_input_buffer: SegmentWriter,
/// Stores RNNoise VAD for segments that are being buffered for FFT
temp_fft_buffer_rnn_vad: f32 = 0,
temp_fft_buffer_vol_ratio: f32 = 0,
/// FFT wrapper for the pipeline that holds the FFT state,
/// our chosen window function, and that can process multiple
/// channels of audio data at once (operating on Segments)
pipeline_fft: PipelineFFT,
/// Temporarily stores the FFT result
temp_pipeline_fft_result: PipelineFFT.Result,
// Speech state machine
vad_machine: VADMachine,
alt_vad_machines: ?[]VADMachine,

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

    var temp_input_segment = Segment{
        .channel_pcm_buf = try allocator.alloc(SplitSlice(f32), n_channels),
        .allocator = allocator,
        .index = undefined,
        .length = undefined,
    };
    errdefer temp_input_segment.deinit();

    var temp_denoiser_segment = try AnalyzedSegment.init(
        allocator,
        pipelineReadSize(config),
        n_channels,
    );
    errdefer temp_denoiser_segment.deinit();

    var fft_input_buffer = try SegmentWriter.init(allocator, n_channels, config.fft_size);
    errdefer fft_input_buffer.deinit();
    // Pipeline sample number that corresponds to the start of the FFT buffer
    fft_input_buffer.segment.index = 0;

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
        .temp_input_segment = temp_input_segment,
        .temp_denoiser_segment = temp_denoiser_segment,
        .fft_input_buffer = fft_input_buffer,
        .pipeline_fft = pipeline_fft,
        .temp_pipeline_fft_result = temp_pipeline_fft_result,
        .vad_machine = undefined,
        .alt_vad_machines = null,
    };

    self.vad_machine = try VADMachine.init(allocator, config.vad_machine_config, self);

    if (config.alt_vad_machine_configs) |alt_vad_configs| {
        self.alt_vad_machines = try allocator.alloc(VADMachine, alt_vad_configs.len);
        var n_alt_vad_initialized: usize = 0;
        errdefer {
            for (0..n_alt_vad_initialized) |i| self.alt_vad_machines.?[i].deinit();
            allocator.free(self.alt_vad_machines.?);
        }

        for (0..alt_vad_configs.len) |i| {
            self.alt_vad_machines.?[i] = try VADMachine.init(allocator, alt_vad_configs[i], self);
        }
    }

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.alt_vad_machines) |alt_vad| {
        for (alt_vad) |*v| v.deinit();
    }
    self.vad_machine.deinit();
    self.denoiser.deinit();
    self.temp_input_segment.deinit();
    self.temp_denoiser_segment.deinit();
    self.fft_input_buffer.deinit();
    self.pipeline_fft.deinit();
    self.temp_pipeline_fft_result.deinit();
}

pub fn run(self: *Self) !void {
    try self.collectInputStep();
}

fn pipelineReadSize(config: Config) usize {
    if (config.use_denoiser) {
        return Denoiser.getFrameSize();
    } else {
        return config.fft_size;
    }
}

fn collectInputStep(self: *Self) !void {
    const frame_size = pipelineReadSize(self.config);
    const p = self.pipeline;

    // While there are enough input samples to form a RNNoise frame
    while (p.total_write_count - self.pipeline_read_count >= frame_size) {
        const from = self.pipeline_read_count;
        const to = from + frame_size;
        self.pipeline_read_count = to;

        var input_segment: *Segment = &self.temp_input_segment;
        try self.pipeline.sliceSegment(input_segment, from, to);

        const pre_analysis = preAnalyzeSegment(input_segment);

        if (self.config.use_denoiser) {
            // Use pre-allocated segment which contains the right segment length
            // for denoising
            var prep_segment: *AnalyzedSegment = &self.temp_denoiser_segment;
            prep_segment.input_segment = input_segment;
            prep_segment.vad = null;
            prep_segment.volume_ratio = pre_analysis.volume_ratio;
            prep_segment.segment.index = input_segment.index;
            try self.denoiserStep(prep_segment);
        } else {
            // We don't need to allocate any memory for `.segment` because
            // we're simply passing the input segment through
            var prep_segment = AnalyzedSegment{
                .input_segment = input_segment,
                .segment = input_segment.*,
                .vad = null,
                .volume_ratio = pre_analysis.volume_ratio,
            };
            try self.fftStep(&prep_segment);
        }
    }
}

const PreAnalysis = struct {
    volume_ratio: f32,
};

fn preAnalyzeSegment(input_segment: *const Segment) PreAnalysis {
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

    const vol_ratio: f32 = if (vol_max == 0) 0 else vol_min / vol_max;

    return PreAnalysis{
        .volume_ratio = vol_ratio,
    };
}

fn denoiserStep(
    self: *Self,
    prep_segment: *AnalyzedSegment,
) !void {
    const n_channels = prep_segment.segment.channel_pcm_buf.len;

    var input_segment: *const Segment = prep_segment.input_segment.?;
    var denoised_segment: *Segment = &prep_segment.segment;

    // We will use the lowest RNNoise VAD of all channels
    var vad_low: f32 = 1;
    for (0..n_channels) |channel_idx| {
        var channel_pcm = input_segment.channel_pcm_buf[channel_idx];
        var result_pcm = denoised_segment.channel_pcm_buf[channel_idx].first;

        const vad = try self.denoiser.denoise(channel_pcm, @constCast(result_pcm));
        if (vad < vad_low) vad_low = vad;
    }

    prep_segment.vad = vad_low;

    try self.fftBufferStep(prep_segment);
}

fn fftBufferStep(
    self: *Self,
    prep_segment: *const AnalyzedSegment,
) !void {
    var fft_buffer = &self.fft_input_buffer;
    const fft_buffer_len = fft_buffer.segment.length;

    const fft_buf_segment: *const Segment = &prep_segment.segment;

    // Denoiser segment could be larger than the FFT buffer (depending on FFT size)
    // So we might have to split it into multiple FFT buffer writes
    var denoised_buf_offset: usize = 0;
    while (true) {
        const written = try fft_buffer.write(fft_buf_segment.*, denoised_buf_offset);
        denoised_buf_offset += written;
        std.debug.assert(denoised_buf_offset <= fft_buf_segment.length);

        const fft_buffer_is_full = fft_buffer.write_index == fft_buffer_len;

        // Keep track of the average RNNoise VAD value for the samples
        // going into the FFT buffer
        const current_segment_share = @intToFloat(f32, written) / @intToFloat(f32, fft_buffer_len);

        // if denoiser was bypassed, we don't have a VAD value
        if (prep_segment.vad) |vad_val| {
            self.temp_fft_buffer_rnn_vad += vad_val * current_segment_share;
        }
        self.temp_fft_buffer_vol_ratio += prep_segment.volume_ratio * current_segment_share;

        if (fft_buffer_is_full) {
            var fft_input = AnalyzedSegment{
                .segment = fft_buffer.segment,
                .vad = if (prep_segment.vad) |rnn_vad| rnn_vad else null,
                .volume_ratio = self.temp_fft_buffer_vol_ratio,
            };

            try self.fftStep(&fft_input);

            // Global index of the first sample in the next segment
            const next_fft_buffer_index = fft_input.segment.index + fft_buffer.segment.length;
            fft_buffer.reset(next_fft_buffer_index);
            self.temp_fft_buffer_rnn_vad = 0;
            self.temp_fft_buffer_vol_ratio = 0;
        }

        // We have written the entirety of the source segment
        if (denoised_buf_offset == fft_buf_segment.length) {
            break;
        }
    }
}

fn fftStep(self: *Self, fft_input: *const AnalyzedSegment) !void {
    try self.pipeline_fft.fft(fft_input.segment, &self.temp_pipeline_fft_result);
    try self.stateMachineStep(fft_input, &self.temp_pipeline_fft_result);
}

fn stateMachineStep(
    self: *Self,
    fft_input: *const AnalyzedSegment,
    fft_result: *const PipelineFFT.Result,
) !void {
    const vad_result = try self.vad_machine.run(fft_input, fft_result);

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

    // Run the VAD machines for the alternative VADs (training)
    if (self.alt_vad_machines) |alt_vads| {
        for (alt_vads) |*alt_vad| {
            _ = try alt_vad.run(fft_input, &self.temp_pipeline_fft_result);
        }
    }
}

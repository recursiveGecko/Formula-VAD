const std = @import("std");
const log = std.log.scoped(.vad);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const BufferedFFT = @import("./BufferedFFT.zig");
const window_fn = @import("../audio_utils/window_fn.zig");
const AudioPipeline = @import("../AudioPipeline.zig");
const Denoiser = @import("../Denoiser.zig");
const SplitSlice = @import("../structures/SplitSlice.zig").SplitSlice;
const Segment = @import("./Segment.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const VADMachine = @import("./VADMachine.zig");
const VADMetadata = @import("./VADMetadata.zig");
const BufferedVolumeAnalyzer = @import("./BufferedVolumeAnalyzer.zig");
const BufferedDenoiser = @import("./BufferedDenoiser.zig");
const BufferedStep = @import("./BufferedStep.zig");
const audio_utils = @import("../audio_utils.zig");

const Self = @This();

pub const Config = struct {
    fft_size: usize = 2048,
    use_denoiser: bool = true,
    vad_machine_config: VADMachine.Config = .{},
    // Alternative state machine configs for training
    alt_vad_machine_configs: ?[]const VADMachine.Config = null,
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

allocator: Allocator,
pipeline: *AudioPipeline,
config: Config,
sample_rate: usize,
n_channels: usize,
/// Number of samples VAD has read from the pipeline
pipeline_read_count: u64 = 0,
/// Temporarily stores slices of pipeline audio data
temp_input_segment: Segment,
buffered_volume_analyzer: BufferedVolumeAnalyzer,
buffered_denoiser: BufferedDenoiser,
buffered_fft: BufferedFFT,
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

    var temp_input_segment = Segment{
        .channel_pcm_buf = try allocator.alloc(SplitSlice(f32), n_channels),
        .allocator = allocator,
        .index = undefined,
        .length = undefined,
    };
    errdefer temp_input_segment.deinit();
    for (0..n_channels) |i| {
        temp_input_segment.channel_pcm_buf[i] = .{
            .owned_slices = .none,
            .first = &.{},
        };
    }

    var buffered_volume_analyzer = try BufferedVolumeAnalyzer.init(allocator);
    errdefer buffered_volume_analyzer.deinit();

    var buffered_denoiser = try BufferedDenoiser.init(allocator, n_channels);
    errdefer buffered_denoiser.deinit();

    var buffered_fft = try BufferedFFT.init(allocator, .{
        .n_channels = n_channels,
        .fft_size = config.fft_size,
        .hop_size = config.fft_size,
        .sample_rate = sample_rate,
    });
    errdefer buffered_fft.deinit();

    var self = Self{
        .allocator = allocator,
        .pipeline = pipeline,
        .config = config,
        .n_channels = n_channels,
        .sample_rate = sample_rate,
        .temp_input_segment = temp_input_segment,
        .buffered_volume_analyzer = buffered_volume_analyzer,
        .buffered_denoiser = buffered_denoiser,
        .buffered_fft = buffered_fft,
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
            n_alt_vad_initialized = i + 1;
        }
    }

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.alt_vad_machines) |alt_vad| {
        for (alt_vad) |*v| v.deinit();
        self.allocator.free(alt_vad);
    }
    self.vad_machine.deinit();
    self.temp_input_segment.deinit();
    self.buffered_volume_analyzer.deinit();
    self.buffered_denoiser.deinit();
    self.buffered_fft.deinit();
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
    const p_total_write_count = p.multi_ring_buffer.total_write_count;

    // While there are enough input samples to form a RNNoise frame
    while (p_total_write_count - self.pipeline_read_count >= frame_size) {
        const from = self.pipeline_read_count;
        const to = from + frame_size;
        self.pipeline_read_count = to;

        var input_segment: *Segment = &self.temp_input_segment;
        try self.pipeline.sliceSegment(input_segment, from, to);

        const input_step_result = BufferedStep.Result{
            .segment = input_segment,
            .metadata = .{},
        };
        var analyzed_step_result = self.buffered_volume_analyzer.write(&input_step_result);

        if (self.config.use_denoiser) {
            try self.denoiserStep(&analyzed_step_result);
        } else {
            try self.fftStep(&analyzed_step_result);
        }
    }
}

fn denoiserStep(
    self: *Self,
    input: *const BufferedStep.Result,
) !void {
    var input_offset: usize = 0;
    while (true) {
        var denoised_result = try self.buffered_denoiser.write(input, input_offset);

        if (denoised_result.denoised_segment == null) return;

        var fft_input = BufferedStep.Result{
            .segment = denoised_result.denoised_segment.?,
            .metadata = denoised_result.metadata.?,
        };
        try self.fftStep(&fft_input);

        if (denoised_result.n_remaining_input == 0) return;
        input_offset = input.segment.length - denoised_result.n_remaining_input;
    }
}

fn fftStep(
    self: *Self,
    input: *const BufferedStep.Result,
) !void {
    // Denoiser segment could be larger than the FFT buffer (depending on FFT size)
    // So we might have to split it into multiple FFT buffer writes
    var input_offset: usize = 0;
    while (true) {
        const result = try self.buffered_fft.write(input, input_offset);
        if (result.fft_result == null) return;

        try self.stateMachineStep(&result.fft_result.?);

        if (result.n_remaining_input == 0) return;
        input_offset = input.segment.length - result.n_remaining_input;
    }
}

fn stateMachineStep(
    self: *Self,
    fft_step_result: *const BufferedFFT.Result,
) !void {
    const vad_result = try self.vad_machine.run(fft_step_result);

    switch (vad_result.recording_state) {
        .started => {
            try self.pipeline.startRecording(vad_result.sample_number);
        },
        .completed => {
            try self.pipeline.endRecording(vad_result.sample_number, true);
        },
        .aborted => {
            try self.pipeline.endRecording(vad_result.sample_number, false);
        },
        .none => {},
    }

    // Run the VAD machines for the alternative VADs (training)
    if (self.alt_vad_machines) |alt_vads| {
        for (alt_vads) |*alt_vad| {
            _ = try alt_vad.run(fft_step_result);
        }
    }
}

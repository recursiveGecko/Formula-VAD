const std = @import("std");
const log = std.log.scoped(.vad);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const BufferedFFT = @import("./BufferedFFT.zig");
const window_fn = @import("../audio_utils/window_fn.zig");
const AudioPipeline = @import("../AudioPipeline.zig");
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
    fft_size: usize = 1024,
    vad_machine_config: VADMachine.Config = .{},
    // Alternative state machine configs for training
    alt_vad_machine_configs: ?[]const VADMachine.Config = null,
    denoiser_model_path: ?[:0]const u8 = null,
};

pub const SpeechSegment = struct {
    sample_from: usize,
    sample_to: usize,
    avg_channel_vol_ratio: f32,
    vad_met_sec: f32,
};

allocator: Allocator,
pipeline: *AudioPipeline,
config: Config,
sample_rate: usize,
n_channels: usize,
/// Number of samples VAD has read from the pipeline
pipeline_read_count: u64 = 0,
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
        std.debug.panic("Unsupported sample rate: {d}", .{sample_rate});
    }

    var allocator = pipeline.allocator;

    var buffered_volume_analyzer = try BufferedVolumeAnalyzer.init(allocator);
    errdefer buffered_volume_analyzer.deinit();

    var buffered_denoiser = try BufferedDenoiser.init(
        allocator,
        n_channels,
        sample_rate,
        config.denoiser_model_path,
    );
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
    self.buffered_volume_analyzer.deinit();
    self.buffered_denoiser.deinit();
    self.buffered_fft.deinit();
}

pub fn run(self: *Self) !void {
    try self.collectInputStep();
}

fn collectInputStep(self: *Self) !void {
    const frame_size = self.buffered_denoiser.getChunkSize();
    const p = self.pipeline;

    while (p.totalWriteCount() - self.pipeline_read_count >= frame_size) {
        const from = self.pipeline_read_count;
        const to = from + frame_size;
        self.pipeline_read_count = to;

        const split_slice = try self.pipeline.sliceSegment(from, to);

        const split_input_1 = BufferedStep.Result{
            .segment = &Segment{
                .index = split_slice.first_index,
                .channel_pcm_buf = split_slice.first,
            },
            .metadata = .{},
        };
        const split_input_2 = BufferedStep.Result{
            .segment = &Segment{
                .index = split_slice.second_index,
                .channel_pcm_buf = split_slice.second,
            },
            .metadata = .{},
        };

        // std.debug.print("collectInput: {d}, {d}\n", .{ split_input_1.segment.length(), split_input_2.segment.length() });

        const result_1 = self.buffered_volume_analyzer.write(&split_input_1);
        const result_2 = self.buffered_volume_analyzer.write(&split_input_2);

        try self.denoiserStep(&result_1);
        try self.denoiserStep(&result_2);
    }
}

fn denoiserStep(
    self: *Self,
    input: *const BufferedStep.Result,
) !void {
    var input_offset: usize = 0;
    while (true) {
        const denoised_result = try self.buffered_denoiser.write(input, input_offset);

        if (denoised_result.denoised_segment == null) return;

        var fft_input = BufferedStep.Result{
            .segment = denoised_result.denoised_segment.?,
            .metadata = denoised_result.metadata.?,
        };

        try self.fftStep(&fft_input);

        if (denoised_result.n_remaining_input == 0) return;
        input_offset = input.segment.length() - denoised_result.n_remaining_input;
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
        input_offset = input.segment.length() - result.n_remaining_input;
    }
}

fn stateMachineStep(
    self: *Self,
    fft_result: *const BufferedFFT.Result,
) !void {
    const vad_result = try self.vad_machine.run(fft_result);

    switch (vad_result.recording_state) {
        .started => {
            log.info("Starting recording at: {d}", .{vad_result.sample_number});
            try self.pipeline.startRecording(vad_result.sample_number);
        },
        .completed => {
            log.info("Completing recording at: {d}", .{vad_result.sample_number});
            try self.pipeline.endRecording(vad_result.sample_number, true);
        },
        .aborted => {
            log.info("Aborting recording at: {d}", .{vad_result.sample_number});
            try self.pipeline.endRecording(vad_result.sample_number, false);
        },
        .none => {},
    }

    // Run the VAD machines for the alternative VADs (training)
    if (self.alt_vad_machines) |alt_vads| {
        for (alt_vads) |*alt_vad| {
            _ = try alt_vad.run(fft_result);
        }
    }
}

test {
    _ = std.testing.refAllDecls(@This());
}

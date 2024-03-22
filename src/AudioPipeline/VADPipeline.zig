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
const BufferedStep = @import("./BufferedStep.zig");
const BufferedNSNet2Denoiser = @import("./BufferedNSNet2Denoiser.zig");
const BufferedDFNDenoiser = @import("./BufferedDFNDenoiser.zig");
const BufferedMixer = @import("BufferedMixer.zig");
const BufferedRecorder = @import("BufferedRecorder.zig");
const audio_utils = @import("../audio_utils.zig");
const types = @import("../types.zig");

const Self = @This();

const DenoiserModule = BufferedDFNDenoiser;

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
b_first_step: *BufferedStep,
b_original_recorder: *BufferedRecorder,
b_mixer: *BufferedMixer,
b_denoiser: *DenoiserModule,
b_denoiser_recorder: *BufferedRecorder,
b_fft: *BufferedFFT,
// Speech state machine
vad_machine: VADMachine,
alt_vad_machines: ?[]VADMachine,

pub fn init(pipeline: *AudioPipeline, config: Config) !*Self {
    const sample_rate = pipeline.config.sample_rate;
    const n_channels = pipeline.config.n_channels;

    if (sample_rate != 48000) {
        std.debug.panic("Unsupported sample rate: {d}", .{sample_rate});
    }

    var allocator = pipeline.allocator;

    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = Self{
        .allocator = allocator,
        .pipeline = pipeline,
        .config = config,
        .n_channels = n_channels,
        .sample_rate = sample_rate,
        .b_first_step = undefined,
        .b_original_recorder = undefined,
        .b_mixer = undefined,
        .b_denoiser = undefined,
        .b_denoiser_recorder = undefined,
        .b_fft = undefined,
        .vad_machine = undefined,
        .alt_vad_machines = null,
    };

    self.b_original_recorder = try BufferedRecorder.init(
        allocator,
        "rec-original",
        pipeline.recording_coordinator,
        sample_rate,
        n_channels,
        true,
    );
    errdefer self.b_original_recorder.deinit();

    self.b_mixer = try BufferedMixer.init(allocator, "mixer", sample_rate, 2, true);
    errdefer self.b_mixer.deinit();

    self.b_denoiser = try DenoiserModule.init(
        allocator,
        "denoiser",
        config.denoiser_model_path,
        self.b_mixer.audio_config.out_sample_rate,
        true,
    );
    errdefer self.b_denoiser.deinit();

    self.b_denoiser_recorder = try BufferedRecorder.init(
        allocator,
        "rec-denoiser",
        pipeline.recording_coordinator,
        self.b_denoiser.audio_config.out_sample_rate,
        self.b_denoiser.audio_config.out_channels,
        true,
    );
    errdefer self.b_denoiser_recorder.deinit();

    self.b_fft = try BufferedFFT.init(
        allocator,
        "fft",
        .{
            .fft_size = config.fft_size,
            .hop_size = config.fft_size,
            .sample_rate = self.b_denoiser.audio_config.out_sample_rate,
        },
        self,
    );
    errdefer self.b_fft.deinit();

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

    // Wire the steps
    self.b_first_step = self.b_original_recorder.step;
    try self.b_original_recorder.step.connectTo(self.b_mixer.step);
    try self.b_mixer.step.connectTo(self.b_denoiser.step);
    try self.b_denoiser.step.connectTo(self.b_denoiser_recorder.step);
    try self.b_denoiser_recorder.step.connectTo(self.b_fft.step);

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.alt_vad_machines) |alt_vad| {
        for (alt_vad) |*v| v.deinit();
        self.allocator.free(alt_vad);
    }
    self.vad_machine.deinit();
    self.b_original_recorder.deinit();
    self.b_mixer.deinit();
    self.b_denoiser.deinit();
    self.b_denoiser_recorder.deinit();
    self.b_fft.deinit();
    self.allocator.destroy(self);
}

pub fn write(self: *Self, segment: *const Segment) !void {
    const input = BufferedStep.Result.wrapSegment(segment);
    try self.b_first_step.write(&input);
}

pub fn onFFTResult(
    self: *Self,
    buffered_step_output: *const BufferedStep.Result,
    fft_result: *const BufferedFFT.FFTResult,
) void {
    self.handleFFTResult(buffered_step_output, fft_result) catch |err| {
        std.debug.panic("VADPipeline.onFFTResult() failed with: {any}", .{err});
    };
}

fn handleFFTResult(
    self: *Self,
    buffered_step_output: *const BufferedStep.Result,
    fft_result: *const BufferedFFT.FFTResult,
) !void {
    _ = buffered_step_output;

    const vad_result = try self.vad_machine.run(fft_result);

    switch (vad_result.recording_state) {
        .started => {
            log.info("Starting recording at: {d}", .{vad_result.sample_number});
            self.pipeline.startRecording(vad_result.sample_number);
        },
        .completed => {
            log.info("Completing recording at: {d}", .{vad_result.sample_number});
            self.pipeline.endRecording(vad_result.sample_number, true);
        },
        .aborted => {
            log.info("Aborting recording at: {d}", .{vad_result.sample_number});
            self.pipeline.endRecording(vad_result.sample_number, false);
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

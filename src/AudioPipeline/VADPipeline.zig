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
const BufferedVolumeAnalyzer = @import("./BufferedVolumeAnalyzer.zig");
const BufferedDenoiser = @import("./BufferedDenoiser.zig");
const BufferedMixer = @import("BufferedMixer.zig");
const audio_utils = @import("../audio_utils.zig");
const types = @import("../types.zig");

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
buffered_mixer: *BufferedMixer,
buffered_denoiser: *BufferedDenoiser,
buffered_fft: *BufferedFFT,
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
        .buffered_mixer = undefined,
        .buffered_denoiser = undefined,
        .buffered_fft = undefined,
        .vad_machine = undefined,
        .alt_vad_machines = null,
    };

    self.buffered_mixer = try BufferedMixer.init(allocator, "mixer", 48000, 2, true);
    errdefer self.buffered_mixer.deinit();

    self.buffered_denoiser = try BufferedDenoiser.init(
        allocator,
        "denoiser",
        config.denoiser_model_path,
        sample_rate,
        true,
    );
    errdefer self.buffered_denoiser.deinit();

    self.buffered_fft = try BufferedFFT.init(
        allocator,
        "fft",
        .{
            .fft_size = config.fft_size,
            .hop_size = config.fft_size,
            .sample_rate = sample_rate,
        },
        self,
    );
    errdefer self.buffered_fft.deinit();

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
    try self.buffered_mixer.step.connectTo(self.buffered_denoiser.step);
    try self.buffered_denoiser.step.connectTo(self.buffered_fft.step);

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.alt_vad_machines) |alt_vad| {
        for (alt_vad) |*v| v.deinit();
        self.allocator.free(alt_vad);
    }
    self.vad_machine.deinit();
    self.buffered_mixer.deinit();
    self.buffered_denoiser.deinit();
    self.buffered_fft.deinit();
    self.allocator.destroy(self);
}

pub fn run(self: *Self) !void {
    const from = self.pipeline_read_count;
    const to = self.pipeline.totalWriteCount();
    self.pipeline_read_count = to;

    const split_slice = try self.pipeline.readRingBuffer(from, to);
    defer split_slice.release();

    const split_segments = types.splitSliceToSegments(split_slice);
    const split_buffered_steps = types.splitSegmentsToBufferedSteps(&split_segments);

    try self.buffered_mixer.step.write(&split_buffered_steps.first);
    try self.buffered_mixer.step.write(&split_buffered_steps.second);
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

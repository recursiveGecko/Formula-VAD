const std = @import("std");
const log = std.log.scoped(.pipeline);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Segment = @import("./AudioPipeline/Segment.zig");
const MRBRecorder = @import("./AudioPipeline/MRBRecorder.zig");
const AudioMRB = @import("./types.zig").AudioMRB;
const AudioBuffer = @import("./audio_utils/AudioBuffer.zig");
const RecordingCoordinator = @import("RecordingCoordinator.zig");
const VADMachine = @import("./AudioPipeline/VADMachine.zig");
const SileroVADMachine = @import("./AudioPipeline/SileroVADMachine.zig");
const BufferedStep = @import("./AudioPipeline/BufferedStep.zig");
const BufferedNSNet2Denoiser = @import("./AudioPipeline/BufferedNSNet2Denoiser.zig");
const BufferedDFNDenoiser = @import("./AudioPipeline/BufferedDFNDenoiser.zig");
const BufferedMixer = @import("./AudioPipeline/BufferedMixer.zig");
const BufferedFFT = @import("./AudioPipeline/BufferedFFT.zig");
const BufferedRecorder = @import("./AudioPipeline/BufferedRecorder.zig");
const BufferedSileroVAD = @import("./AudioPipeline/BufferedSileroVAD.zig");
const DataLogger = @import("./DataLogger.zig");

const Self = @This();

pub const Callbacks = struct {
    ctx: *anyopaque,
    on_recording: ?*const fn (
        ctx: *anyopaque,
        recorder_name: []const u8,
        recording: AudioBuffer,
    ) void,
};

pub const Config = struct {
    pub const VADConfig = struct {
        fft_size: usize = 1024,
        // TODO: used to be 20
        attenuation: f32 = 30,
        vad_machine_config: VADMachine.Config = .{},
        denoiser_model_path: [:0]const u8 = "data/DeepFilterNet3_onnx.tar.gz",
    };

    pub const RecordingTarget = enum { all, original, none };

    sample_rate: usize,
    n_channels: usize,
    vad_config: VADConfig = .{},
    /// Caller continues to own the DataLogger connection and must close it when done
    data_logger: ?*DataLogger.Conn = null,
    record: RecordingTarget,
};

pub const SpeechSegment = struct {
    /// Reported values (to give some buffer and ensure we don't cut off speech)
    sample_from: u64,
    sample_to: u64,
    /// Actual values
    detected_sample_from: u64,
    detected_sample_to: u64,
    avg_channel_vol_ratio: f32,
    vad_met_sec: f32,
};

allocator: Allocator,
config: Config,
callbacks: ?Callbacks = null,
recording_coordinator: *RecordingCoordinator,
write_index: u64 = 0,
// VAD Pipeline
b_first_step: *BufferedStep,
b_original_recorder: *BufferedRecorder,
b_mixer: *BufferedMixer,
b_denoiser: *BufferedDFNDenoiser,
b_denoiser_recorder: *BufferedRecorder,
b_fft: *BufferedFFT,
b_silero_vad: *BufferedSileroVAD,
data_logger: ?*DataLogger.Conn,
// Speech state machine
vad_machine: SileroVADMachine,

pub fn init(
    allocator: Allocator,
    config: Config,
    callbacks: ?Callbacks,
) !*Self {
    const n_channels = config.n_channels;
    const in_sample_rate = config.sample_rate;
    if (in_sample_rate != 48000) {
        std.debug.panic("Unsupported sample rate: {d}", .{in_sample_rate});
    }

    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = Self{
        .config = config,
        .allocator = allocator,
        .callbacks = callbacks,
        .data_logger = config.data_logger,
        .recording_coordinator = undefined,
        .b_first_step = undefined,
        .b_original_recorder = undefined,
        .b_mixer = undefined,
        .b_denoiser = undefined,
        .b_denoiser_recorder = undefined,
        .b_fft = undefined,
        .b_silero_vad = undefined,
        .vad_machine = undefined,
    };

    self.recording_coordinator = try RecordingCoordinator.init(allocator, self);
    errdefer self.recording_coordinator.deinit();

    self.b_original_recorder = try BufferedRecorder.init(
        allocator,
        "rec-original",
        self.recording_coordinator,
        in_sample_rate,
        n_channels,
        true,
    );
    errdefer self.b_original_recorder.deinit();

    self.b_mixer = try BufferedMixer.init(
        allocator,
        "mixer",
        self.b_original_recorder.step.audio_config.out_sample_rate,
        self.b_original_recorder.step.audio_config.out_channels,
        true,
    );
    errdefer self.b_mixer.deinit();

    self.b_denoiser = try BufferedDFNDenoiser.init(
        allocator,
        "denoiser",
        config.vad_config.attenuation,
        config.vad_config.denoiser_model_path,
        self.b_mixer.step.audio_config.out_sample_rate,
        true,
    );
    errdefer self.b_denoiser.deinit();

    self.b_denoiser_recorder = try BufferedRecorder.init(
        allocator,
        "rec-denoiser",
        self.recording_coordinator,
        self.b_denoiser.step.audio_config.out_sample_rate,
        self.b_denoiser.step.audio_config.out_channels,
        true,
    );
    errdefer self.b_denoiser_recorder.deinit();

    self.b_silero_vad = try BufferedSileroVAD.init(
        allocator,
        "silero",
        self.b_denoiser_recorder.step.audio_config.out_sample_rate,
        true,
    );
    errdefer self.b_silero_vad.deinit();

    self.b_fft = try BufferedFFT.init(
        allocator,
        "fft",
        .{
            .fft_size = config.vad_config.fft_size,
            .hop_size = config.vad_config.fft_size,
            .sample_rate = self.b_silero_vad.step.audio_config.out_sample_rate,
        },
        self,
    );
    errdefer self.b_fft.deinit();

    // self.vad_machine = try VADMachine.init(allocator, config.vad_config.vad_machine_config, self.config);
    self.vad_machine = try SileroVADMachine.init(allocator, self.b_fft.step);

    // Wire the steps
    self.b_first_step = self.b_original_recorder.step;
    try self.b_original_recorder.step.connectTo(self.b_mixer.step);
    try self.b_mixer.step.connectTo(self.b_denoiser.step);
    try self.b_denoiser.step.connectTo(self.b_denoiser_recorder.step);
    try self.b_denoiser_recorder.step.connectTo(self.b_silero_vad.step);
    try self.b_silero_vad.step.connectTo(self.b_fft.step);

    switch (config.record) {
        .all => self.recording_coordinator.enableAll(),
        .original => try self.recording_coordinator.enableOne(self.b_original_recorder),
        .none => {},
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.vad_machine.deinit();
    self.b_original_recorder.deinit();
    self.b_mixer.deinit();
    self.b_denoiser.deinit();
    self.b_denoiser_recorder.deinit();
    self.b_fft.deinit();
    self.b_silero_vad.deinit();
    self.recording_coordinator.deinit();
    self.allocator.destroy(self);
}

pub fn pushSamples(self: *Self, channel_pcm: []const []const f32) !u64 {
    const segment = Segment.wrapChannelPcmBuf(self.write_index, channel_pcm);
    self.write_index += segment.length();
    const input_result = BufferedStep.Result.wrapSegment(&segment);

    try self.b_first_step.write(&input_result);
    return segment.index;
}

pub fn onFFTResult(
    self: *Self,
    buffered_step_output: *const BufferedStep.Result,
    fft_result: *const BufferedFFT.FFTResult,
) void {
    self.handleFFTResult(buffered_step_output, fft_result) catch |err| {
        std.debug.panic("AudioPipeline.onFFTResult() failed with: {any}", .{err});
    };
}

fn handleFFTResult(
    self: *Self,
    buffered_step_output: *const BufferedStep.Result,
    fft_result: *const BufferedFFT.FFTResult,
) !void {
    const vad_result = try self.vad_machine.run(buffered_step_output, fft_result);
    const root_sample_number = self.b_fft.step.convertSampleIndexToRoot(vad_result.sample_number);

    switch (vad_result.recording_state) {
        .started => {
            log.info("Starting recording at: {d}", .{root_sample_number.from});
            self.recording_coordinator.start(root_sample_number.from);
        },
        .completed => {
            log.info("Completing recording at: {d}", .{root_sample_number.to});
            self.recording_coordinator.stop(root_sample_number.to, true);
        },
        .aborted => {
            log.info("Aborting recording at: {d}", .{root_sample_number.to});
            self.recording_coordinator.stop(root_sample_number.to, false);
        },
        .none => {},
    }

    if (self.data_logger) |dl| {
        try dl.logVAD(.{
            .fft = fft_result,
            .output = buffered_step_output,
            .silero_vad = vad_result.instant_silero_vad,
        });
    }
}

pub fn onRecording(
    self: *Self,
    recorder_name: []const u8,
    audio_buffer: AudioBuffer,
) void {
    defer audio_buffer.deinit();
    const cb_config = self.callbacks orelse return;

    if (cb_config.on_recording) |cb| {
        cb(cb_config.ctx, recorder_name, audio_buffer);
    }
}

//
// Tests
//

test {
    std.testing.refAllDecls(@This());
}

test "simple leak test" {
    var pipeline = try init(
        std.testing.allocator,
        .{
            .n_channels = 2,
            .sample_rate = 48000,
            .vad_config = .{},
            .record = .none,
        },
        null,
    );
    defer pipeline.deinit();
}

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
const BufferedStep = @import("./AudioPipeline/BufferedStep.zig");
const BufferedNSNet2Denoiser = @import("./AudioPipeline/BufferedNSNet2Denoiser.zig");
const BufferedDFNDenoiser = @import("./AudioPipeline/BufferedDFNDenoiser.zig");
const BufferedMixer = @import("./AudioPipeline/BufferedMixer.zig");
const BufferedFFT = @import("./AudioPipeline/BufferedFFT.zig");
const BufferedRecorder = @import("./AudioPipeline/BufferedRecorder.zig");

const Self = @This();

const DenoiserModule = BufferedDFNDenoiser;

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
        vad_machine_config: VADMachine.Config = .{},
        // Alternative state machine configs for training
        alt_vad_machine_configs: ?[]const VADMachine.Config = null,
        denoiser_model_path: ?[:0]const u8 = null,
    };

    pub const RecordingTarget = enum { all, original, none };

    sample_rate: usize,
    n_channels: usize,
    buffer_length: ?usize = null,
    vad_config: VADConfig = .{},
    skip_processing: bool = false,
    record: RecordingTarget,
};

pub const SpeechSegment = struct {
    sample_from: usize,
    sample_to: usize,
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
b_denoiser: *DenoiserModule,
b_denoiser_recorder: *BufferedRecorder,
b_fft: *BufferedFFT,
// Speech state machine
vad_machine: VADMachine,
alt_vad_machines: ?[]VADMachine,

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
        .recording_coordinator = undefined,
        .b_first_step = undefined,
        .b_original_recorder = undefined,
        .b_mixer = undefined,
        .b_denoiser = undefined,
        .b_denoiser_recorder = undefined,
        .b_fft = undefined,
        .vad_machine = undefined,
        .alt_vad_machines = null,
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
        self.b_original_recorder.audio_config.out_sample_rate,
        2,
        true,
    );
    errdefer self.b_mixer.deinit();

    self.b_denoiser = try DenoiserModule.init(
        allocator,
        "denoiser",
        config.vad_config.denoiser_model_path,
        self.b_mixer.audio_config.out_sample_rate,
        true,
    );
    errdefer self.b_denoiser.deinit();

    self.b_denoiser_recorder = try BufferedRecorder.init(
        allocator,
        "rec-denoiser",
        self.recording_coordinator,
        self.b_denoiser.audio_config.out_sample_rate,
        self.b_denoiser.audio_config.out_channels,
        true,
    );
    errdefer self.b_denoiser_recorder.deinit();

    self.b_fft = try BufferedFFT.init(
        allocator,
        "fft",
        .{
            .fft_size = config.vad_config.fft_size,
            .hop_size = config.vad_config.fft_size,
            .sample_rate = self.b_denoiser_recorder.audio_config.out_sample_rate,
        },
        self,
    );
    errdefer self.b_fft.deinit();

    self.vad_machine = try VADMachine.init(allocator, config.vad_config.vad_machine_config, self.config);

    if (config.vad_config.alt_vad_machine_configs) |alt_vad_configs| {
        self.alt_vad_machines = try allocator.alloc(VADMachine, alt_vad_configs.len);
        var n_alt_vad_initialized: usize = 0;
        errdefer {
            for (0..n_alt_vad_initialized) |i| self.alt_vad_machines.?[i].deinit();
            allocator.free(self.alt_vad_machines.?);
        }

        for (0..alt_vad_configs.len) |i| {
            self.alt_vad_machines.?[i] = try VADMachine.init(
                allocator,
                alt_vad_configs[i],
                self.config,
            );
            n_alt_vad_initialized = i + 1;
        }
    }

    // Wire the steps
    self.b_first_step = self.b_original_recorder.step;
    try self.b_original_recorder.step.connectTo(self.b_mixer.step);
    try self.b_mixer.step.connectTo(self.b_denoiser.step);
    try self.b_denoiser.step.connectTo(self.b_denoiser_recorder.step);
    try self.b_denoiser_recorder.step.connectTo(self.b_fft.step);

    switch (config.record) {
        .all => {},
        .none => self.recording_coordinator.disableAll(),
        .original => {
            self.recording_coordinator.disableAll();
            try self.recording_coordinator.enableOne(self.b_original_recorder);
        },
    }

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
    self.recording_coordinator.deinit();
    self.allocator.destroy(self);
}

pub fn totalWriteCount(self: *const Self) u64 {
    return self.ring_buffer.total_write_count;
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
    _ = buffered_step_output;

    const vad_result = try self.vad_machine.run(fft_result);

    switch (vad_result.recording_state) {
        .started => {
            log.info("Starting recording at: {d}", .{vad_result.sample_number});
            self.recording_coordinator.start(vad_result.sample_number);
        },
        .completed => {
            log.info("Completing recording at: {d}", .{vad_result.sample_number});
            self.recording_coordinator.stop(vad_result.sample_number, true);
        },
        .aborted => {
            log.info("Aborting recording at: {d}", .{vad_result.sample_number});
            self.recording_coordinator.stop(vad_result.sample_number, false);
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

test "simple leak test" {
    var pipeline = try init(
        std.testing.allocator,
        .{
            .n_channels = 2,
            .sample_rate = 48000,
            .vad_config = .{
                .alt_vad_machine_configs = &.{
                    .{},
                    .{},
                },
            },
        },
        null,
    );
    defer pipeline.deinit();
}

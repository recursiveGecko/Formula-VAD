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
buffered_volume_analyzer: BufferedVolumeAnalyzer,
buffered_fft: BufferedFFT,
// new buffered steps
buffered_mixer: *BufferedMixer,
buffered_denoiser: *BufferedDenoiser,
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

    var buffered_fft = try BufferedFFT.init(allocator, .{
        .n_channels = n_channels,
        .fft_size = config.fft_size,
        .hop_size = config.fft_size,
        .sample_rate = sample_rate,
    });
    errdefer buffered_fft.deinit();

    const buffered_mixer = try BufferedMixer.init(allocator, "mixer", 48000, 2, true);
    errdefer buffered_mixer.deinit();

    var buffered_denoiser = try BufferedDenoiser.init(
        allocator,
        "nsnet2",
        config.denoiser_model_path,
        n_channels,
        sample_rate,
        false,
    );
    errdefer buffered_denoiser.deinit();

    // Wire the steps
    try buffered_mixer.step.connectTo(buffered_denoiser.step);

    var self = Self{
        .allocator = allocator,
        .pipeline = pipeline,
        .config = config,
        .n_channels = n_channels,
        .sample_rate = sample_rate,

        .buffered_mixer = buffered_mixer,

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
    self.buffered_mixer.deinit();
    self.buffered_volume_analyzer.deinit();
    self.buffered_denoiser.deinit();
    self.buffered_fft.deinit();
}

pub fn run(self: *Self) !void {
    const from = self.pipeline_read_count;
    const to = self.pipeline.totalWriteCount();
    self.pipeline_read_count = to;

    const split_slice = try self.pipeline.readRingBuffer(from, to);
    const split_segments = types.splitSliceToSegments(&split_slice);
    const split_buffered_steps = types.splitSegmentsToBufferedSteps(&split_segments);

    try self.buffered_mixer.step.write(&split_buffered_steps.first);
    try self.buffered_mixer.step.write(&split_buffered_steps.second);
}

// fn fftStep(
//     self: *Self,
//     input: *const BufferedStep.Result,
// ) !void {
//     // Denoiser segment could be larger than the FFT buffer (depending on FFT size)
//     // So we might have to split it into multiple FFT buffer writes
//     var input_offset: usize = 0;
//     while (true) {
//         const result = try self.buffered_fft.write(input, input_offset);
//         if (result.fft_result == null) return;

//         try self.stateMachineStep(&result.fft_result.?);

//         if (result.n_remaining_input == 0) return;
//         input_offset = input.segment.length() - result.n_remaining_input;
//     }
// }

// fn stateMachineStep(
//     self: *Self,
//     fft_result: *const BufferedFFT.Result,
// ) !void {
//     const vad_result = try self.vad_machine.run(fft_result);

//     switch (vad_result.recording_state) {
//         .started => {
//             log.info("Starting recording at: {d}", .{vad_result.sample_number});
//             try self.pipeline.startRecording(vad_result.sample_number);
//         },
//         .completed => {
//             log.info("Completing recording at: {d}", .{vad_result.sample_number});
//             try self.pipeline.endRecording(vad_result.sample_number, true);
//         },
//         .aborted => {
//             log.info("Aborting recording at: {d}", .{vad_result.sample_number});
//             try self.pipeline.endRecording(vad_result.sample_number, false);
//         },
//         .none => {},
//     }

//     // Run the VAD machines for the alternative VADs (training)
//     if (self.alt_vad_machines) |alt_vads| {
//         for (alt_vads) |*alt_vad| {
//             _ = try alt_vad.run(fft_result);
//         }
//     }
// }

test {
    _ = std.testing.refAllDecls(@This());
}

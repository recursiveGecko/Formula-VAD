const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const FFT = @import("../FFT.zig");
const window_fn = @import("../audio_utils/window_fn.zig");
const Segment = @import("./Segment.zig");
const BufferedStep = @import("./BufferedStep.zig");
const AudioPipeline = @import("../AudioPipeline.zig");
const VADMetadata = @import("./VADMetadata.zig");

const Self = @This();

pub const Config = struct {
    fft_size: usize,
    hop_size: usize,
    sample_rate: usize,
};

pub const FFTResult = struct {
    // Global sample index of the first sample in the FFT window
    allocator: Allocator,
    index: usize,
    sample_rate: usize,
    fft_size: usize,
    freq_bins: []f32 = undefined,
    vad_metadata: VADMetadata.Result,

    pub fn init(
        allocator: Allocator,
        sample_rate: usize,
        fft_size: usize,
    ) !FFTResult {
        const bin_count = FFT.binCount(fft_size);
        const freq_bins = try allocator.alloc(f32, bin_count);
        errdefer allocator.free(freq_bins);

        return FFTResult{
            .allocator = allocator,
            .index = 0,
            .sample_rate = sample_rate,
            .fft_size = fft_size,
            .freq_bins = freq_bins,
            .vad_metadata = .{},
        };
    }

    pub fn deinit(self: *FFTResult) void {
        self.allocator.free(self.freq_bins);
    }
};

allocator: Allocator,
config: Config,
fft_instance: *FFT,
audio_config: BufferedStep.AudioConfig,
pipeline: *AudioPipeline,
step: *BufferedStep,
// window and its normalization factor
window: []const f32,
norm_factor: f32,
// stores intermediate FFT results
complex_buffer: []FFT.Complex,
temp_result: FFTResult,

pub fn init(
    allocator: Allocator,
    name: []const u8,
    config: Config,
    pipeline: *AudioPipeline,
) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    var fft_instance = try FFT.init(
        allocator,
        config.fft_size,
        config.sample_rate,
        false,
    );
    errdefer fft_instance.deinit();

    const temp_result = try FFTResult.init(
        allocator,
        config.sample_rate,
        config.fft_size,
    );

    const window = try allocator.alloc(f32, config.fft_size);
    errdefer allocator.free(window);
    window_fn.hannWindowPeriodic(window);

    const norm_factor = window_fn.windowNormFactor(window) / @as(f32, @floatFromInt(config.fft_size));

    const complex_buffer = try allocator.alloc(FFT.Complex, FFT.binCount(config.fft_size));
    errdefer allocator.free(complex_buffer);

    self.* = Self{
        .allocator = allocator,
        .config = config,
        .temp_result = temp_result,
        .fft_instance = fft_instance,
        .window = window,
        .complex_buffer = complex_buffer,
        .norm_factor = norm_factor,
        .pipeline = pipeline,
        .audio_config = .{
            .buffer_size = config.fft_size,
            .in_channels = 1,
            .in_sample_rate = config.sample_rate,
            .out_channels = 1,
            .out_sample_rate = config.sample_rate,
            .expect_output = false,
        },
        .step = undefined,
    };

    self.step = try BufferedStep.init(
        allocator,
        name,
        self.audio_config,
        BufferedStep.Processor.forContext(self),
    );
    errdefer self.step.deinit();

    return self;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.window);
    self.allocator.free(self.complex_buffer);
    self.fft_instance.deinit();
    self.temp_result.deinit();
    self.step.deinit();
    self.allocator.destroy(self);
}

pub fn process(
    self: *Self,
    input: *const BufferedStep.Result,
) *const BufferedStep.Result {
    const samples = input.segment.channel_pcm_buf[0];
    const freq_bins = self.temp_result.freq_bins;

    self.fft_instance.fft(samples, self.window, self.complex_buffer) catch |err| {
        std.debug.panic(
            "BufferedFFT '{s}': fft() failed with: {any}",
            .{ self.step.name, err },
        );
    };

    for (0..freq_bins.len) |i| {
        freq_bins[i] = self.complex_buffer[i].abs() * self.norm_factor;
    }
    self.temp_result.vad_metadata = input.metadata;
    self.temp_result.index = input.segment.index;
    self.pipeline.onFFTResult(input, &self.temp_result);

    return input;
}

pub fn averageVolumeInBand(
    result: *const FFTResult,
    min_freq: f32,
    max_freq: f32,
) !f32 {
    const min_bin = try FFT.freqToBin(result.sample_rate, min_freq, result.fft_size);
    const max_bin = try FFT.freqToBin(result.sample_rate, max_freq, result.fft_size);

    var avg_vol: f32 = 0;

    for (min_bin..max_bin + 1) |i| {
        avg_vol += result.freq_bins[i];
    }

    return avg_vol;
}

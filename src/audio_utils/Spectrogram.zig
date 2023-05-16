const std = @import("std");
const Allocator = std.mem.Allocator;
const FFT = @import("../FFT.zig");
const SplitSlice = @import("../structures/SplitSlice.zig").SplitSlice;
const window_fn = @import("./window_fn.zig");

const Self = @This();

pub const WindowFunction = enum {
    Rectangular,
    Hann,
    Hamming,
};

pub const SpectrogramOptions = struct {
    sample_rate: usize,
    window_function: WindowFunction = .Hann,
    fft_size: usize = 2048,
    hop_size: usize = 2048,
};

values: []f32,
bin_labels: []const f32,
bin_width: f32,
height: usize,
width: usize,
nyquist_freq: f32,
length_sec: f64,

pub fn compute(allocator: Allocator, samples: []const f32, options: SpectrogramOptions) !Self {
    const fft_size = options.fft_size;
    const hop_size = options.hop_size;

    if (samples.len < fft_size) {
        return error.InsufficientSamples;
    }

    // Steps when incomplete frames are dropped
    const steps = (samples.len - hop_size) / hop_size;

    var fft = try FFT.init(allocator, fft_size, options.sample_rate);
    errdefer fft.deinit();
    const fft_bin_count = fft.binCount();

    const total_bins = fft.binCount() * steps;
    var spectrogram = try allocator.alloc(f32, total_bins);
    errdefer allocator.free(spectrogram);

    const window = try allocator.alloc(f32, fft_size);
    window_fn.hannWindowPeriodic(window);
    defer allocator.free(window);

    var processed_samples: usize = 0;
    var last_result_idx: usize = 0;
    for (0..steps) |i| {
        const samples_from = i * hop_size;
        const samples_to = samples_from + fft_size;
        const fft_samples = samples[samples_from..samples_to];
        const pcm_slice = SplitSlice(f32){.first = fft_samples};

        const result_from = i * fft_bin_count;
        const result_to = result_from + fft_bin_count;
        const result = spectrogram[result_from..result_to];

        try fft.fft(pcm_slice, window, result);

        processed_samples = samples_to;
        last_result_idx = result_to - 1;
    }

    // Check that we wrote the correct number of values
    std.debug.assert(last_result_idx == spectrogram.len - 1);

    var bin_labels = try allocator.alloc(f32, fft_bin_count);
    errdefer allocator.free(bin_labels);

    for (0..bin_labels.len) |i| {
        bin_labels[i] = try fft.binToFreq(i);
    }

    const length_sec: f64 = @intToFloat(f64, processed_samples) / @intToFloat(f64, options.sample_rate);

    var self = Self{
        .values = spectrogram,
        .height = fft_bin_count,
        .width = steps,
        .bin_labels = bin_labels,
        .bin_width = fft.binWidth(),
        .nyquist_freq = fft.nyquistFreq(),
        .length_sec = length_sec,
    };

    return self;
}

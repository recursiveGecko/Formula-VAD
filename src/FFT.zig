//! Wrapper around the KissFFT library

const std = @import("std");
const Allocator = std.mem.Allocator;
const kissfft = @cImport({
    @cInclude("_kiss_fft_guts.h");
    @cInclude("kiss_fft.h");
    @cInclude("kiss_fftr.h");
});
const window_fn = @import("./audio_utils/window_fn.zig");
const SplitSlice = @import("./structures/SplitSlice.zig").SplitSlice;

const Self = @This();

// =============
// Struct fields
// =============
allocator: Allocator,
// kiss_fftr_cfg is a C pointer
kiss_cfg: kissfft.kiss_fftr_cfg,
kiss_state_raw: []align(8) u8,
f_in: []f32,
f_out: []kissfft.kiss_fft_cpx,
n_fft: usize,
sample_rate: usize,

/// Initialize a new reusable FFT instance for given FFT size and sample rate.
pub fn init(allocator: Allocator, n_fft: usize, sample_rate: usize) !Self {
    if (n_fft == 0 or @mod(n_fft, 2) != 0) {
        return error.InvalidFFTSize;
    }

    const state_size_needed = kissfftSizeNeeded(n_fft);

    // Allocate KissFFT state
    const kiss_state_raw = try allocator.alignedAlloc(u8, 8, state_size_needed);
    errdefer allocator.free(kiss_state_raw);

    // KissFFT is going to store the state at the beginning of our allocated buffer
    const kiss_cfg = @ptrCast(kissfft.kiss_fftr_cfg, kiss_state_raw.ptr);

    // Allocate input and output buffers
    const f_in = try allocator.alloc(f32, n_fft);
    errdefer allocator.free(f_in);

    const f_out = try allocator.alloc(kissfft.kiss_fft_cpx, n_fft);
    errdefer allocator.free(f_out);

    var self = Self{
        .allocator = allocator,
        .n_fft = n_fft,
        .kiss_state_raw = kiss_state_raw,
        .kiss_cfg = kiss_cfg,
        .f_in = f_in,
        .f_out = f_out,
        .sample_rate = sample_rate,
    };

    self.resetKissFFT();

    return self;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.kiss_state_raw);
    self.allocator.free(self.f_in);
    self.allocator.free(self.f_out);
}

pub fn fft(self: *Self, samples: SplitSlice(f32), window: []const f32, result: []f32) !void {
    if (samples.len() != self.n_fft) {
        return error.InvalidSamplesLength;
    }

    if (window.len != self.n_fft) {
        return error.InvalidWindowLength;
    }

    if (result.len != self.binCount()) {
        return error.InvalidResultLength;
    }

    // Reset internal state of KissFFT
    self.resetKissFFT();

    // Applies the window function and loads the samples into the KissFFT input buffer
    const in_samples = self.loadSamples(samples, window);

    // Run FFT
    kissfft.kiss_fftr(self.kiss_cfg, in_samples.ptr, self.f_out.ptr);

    // Calculate the normalization factor for the window function
    // so that we can normalize the output into [0, 1] range correctly
    const window_norm = window_fn.windowNormFactor(window);

    // Calculate normalized magnitude of each bin
    self.binOutput(window_norm, result);
}

/// Query the number of usable bins in the FFT output
pub fn binCount(self: Self) usize {
    return (self.n_fft / 2) + 1;
}

/// Query the width of each bin in Hz
pub fn binWidth(self: Self) f32 {
    const sample_rate_f = @intToFloat(f32, self.sample_rate);
    const n_fft_f = @intToFloat(f32, self.n_fft);

    return sample_rate_f / n_fft_f;
}

/// Query the Nyquist frequency of the FFT
pub fn nyquistFreq(self: Self) f32 {
    const sample_rate_f = @intToFloat(f32, self.sample_rate);
    return sample_rate_f / 2;
}

/// Converts given frequency in Hz to the nearest FFT bin index
pub fn freqToBin(self: Self, freq: f32) !usize {
    if (freq > self.nyquistFreq()) {
        return error.OutOfRange;
    }

    if (freq < 0) {
        return error.NegativeFrequency;
    }

    const bin_f = @round(freq / self.binWidth());
    return @floatToInt(usize, bin_f);
}

/// Converts given FFT bin index to the corresponding frequency in Hz
pub fn binToFreq(self: Self, bin_index: usize) !f32 {
    const max_bin_index = self.binCount() - 1;

    if (bin_index > max_bin_index) {
        return error.OutOfRange;
    }

    const bin_f = @intToFloat(f32, bin_index);
    const bin_width = self.binWidth();
    return bin_f * bin_width;
}

/// Loads samples into the KissFFT input buffer
fn loadSamples(self: *Self, samples: SplitSlice(f32), window: []const f32) []const f32 {
    std.debug.assert(samples.len() == window.len);

    for (samples.first, 0..) |sample, idx| {
        self.f_in[idx] = sample * window[idx];
    }

    for (samples.second, samples.first.len..) |sample, idx| {
        self.f_in[idx] = sample * window[idx];
    }

    return self.f_in;
}

/// Calculates normalized magnitude of each bin
fn binOutput(self: *Self, window_norm: f32, result: []f32) void {
    const bin_count = self.binCount();

    const norm_factor = window_norm / @intToFloat(f32, self.n_fft / 2);

    for (0..bin_count) |idx| {
        const r = self.f_out[idx].r;
        const i = self.f_out[idx].i;

        const _r2 = std.math.pow(f32, r, 2);
        const _i2 = std.math.pow(f32, i, 2);

        const magnitude = std.math.sqrt(_r2 + _i2);
        result[idx] = magnitude * norm_factor;
    }
}

fn resetKissFFT(self: *Self) void {
    const c_nfft = @intCast(c_int, self.n_fft);
    var lenmem: usize = self.kiss_state_raw.len;

    const cfg = kissfft.kiss_fftr_alloc(c_nfft, 0, self.kiss_state_raw.ptr, &lenmem);

    // cfg (==kiss_state_raw.ptr) should never be null as we've ensured
    // that we're allocating enough memory using kissfftSizeNeeded
    std.debug.assert(cfg != null);

    // This shouldn't be required
    // self.kiss_cfg = cfg;
}

fn kissfftSizeNeeded(n_fft: usize) usize {
    const c_nfft = @intCast(c_int, n_fft);

    var lenmem: usize = 1;

    // This should fail and store the required buffer size in `lenmem`
    const cfg = kissfft.kiss_fftr_alloc(c_nfft, 0, null, &lenmem);

    if (cfg != null) {
        // This should never succeed as we're passing lenmem that's too small
        // https://github.com/mborgerding/kissfft/blob/8f47a67f595a6641c566087bf5277034be64f24d/kiss_fft.h#L112
        unreachable;
    }

    return lenmem;
}

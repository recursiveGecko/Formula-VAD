//! Wrapper around the KissFFT library

const std = @import("std");
const Allocator = std.mem.Allocator;
const kissfft = @cImport({
    @cInclude("_kiss_fft_guts.h");
    @cInclude("kiss_fft.h");
    @cInclude("kiss_fftr.h");
});

pub const Complex = extern struct {
    r: f32,
    i: f32,

    pub fn abs(self: @This()) f32 {
        return @sqrt(self.r * self.r + self.i * self.i);
    }
};

const Self = @This();

// =============
// Struct fields
// =============
allocator: Allocator,
kiss_cfg: kissfft.kiss_fftr_cfg = null,
buf_real: []f32,
buf_cpx: []kissfft.kiss_fft_cpx,
fft_size: usize,
sample_rate: usize,
mode_inverse: bool,

/// Initialize a new reusable FFT instance for given FFT size and sample rate.
pub fn init(
    allocator: Allocator,
    fft_size: usize,
    sample_rate: usize,
    mode_inverse: bool,
) !*Self {
    if (fft_size == 0 or @mod(fft_size, 2) != 0) {
        return error.InvalidFFTSize;
    }

    // Allocate input and output buffers
    const buf_real = try allocator.alloc(f32, fft_size);
    errdefer allocator.free(buf_real);

    const buf_cpx = try allocator.alloc(kissfft.kiss_fft_cpx, fft_size);
    errdefer allocator.free(buf_cpx);

    const kiss_cfg = kissfft.kiss_fftr_alloc(
        @intCast(fft_size),
        @intFromBool(mode_inverse),
        null,
        null,
    );
    if (kiss_cfg == null) {
        return error.KissFFTAllocFailed;
    }

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = Self{
        .allocator = allocator,
        .fft_size = fft_size,
        .kiss_cfg = kiss_cfg,
        .buf_real = buf_real,
        .buf_cpx = buf_cpx,
        .sample_rate = sample_rate,
        .mode_inverse = mode_inverse,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    kissfft.kiss_fftr_free(self.kiss_cfg);
    self.allocator.free(self.buf_real);
    self.allocator.free(self.buf_cpx);
    self.allocator.destroy(self);
}

pub fn fft(
    self: *Self,
    samples: []const f32,
    window: []const f32,
    bins: []Complex,
) !void {
    if (samples.len != self.fft_size) {
        return error.InvalidSamplesLength;
    }

    if (window.len != self.fft_size) {
        return error.InvalidWindowLength;
    }

    if (bins.len != binCount(self.fft_size)) {
        std.debug.print("bins.len: {} {}\n", .{ bins.len, binCount(self.fft_size) });
        return error.InvalidResultLength;
    }

    // Applies the window function and loads the samples into the KissFFT input buffer
    const in_samples = self.loadSamplesFwd(samples, window);

    // Run FFT
    kissfft.kiss_fftr(
        self.kiss_cfg,
        in_samples.ptr,
        @ptrCast(bins.ptr),
    );
}

pub fn invFft(
    self: *Self,
    bins: []const Complex,
    result: []f32,
) !void {
    if (bins.len != binCount(self.fft_size)) {
        return error.InvalidBinsLength;
    }

    if (result.len != self.fft_size) {
        return error.InvalidResultLength;
    }

    // Run FFT
    kissfft.kiss_fftri(
        self.kiss_cfg,
        @ptrCast(bins.ptr),
        result.ptr,
    );
}

/// Query the number of usable bins in the FFT output
pub fn binCount(fft_size: usize) usize {
    return (fft_size / 2) + 1;
}

/// Query the width of each bin in Hz
pub fn binWidth(sample_rate: usize, fft_size: usize) f32 {
    const sample_rate_f: f32 = @floatFromInt(sample_rate);
    const fft_size_f: f32 = @floatFromInt(fft_size);

    return sample_rate_f / fft_size_f;
}

/// Query the Nyquist frequency of the FFT
pub fn nyquistFreq(sample_rate: usize) f32 {
    const sample_rate_f: f32 = @floatFromInt(sample_rate);
    return sample_rate_f / 2;
}

/// Converts given frequency in Hz to the nearest FFT bin index
pub fn freqToBin(sample_rate: usize, freq: f32, fft_size: usize) !usize {
    if (freq > nyquistFreq(sample_rate)) {
        return error.OutOfRange;
    }

    if (freq < 0) {
        return error.NegativeFrequency;
    }

    const bin_f = @round(freq / binWidth(sample_rate, fft_size));
    return @intFromFloat(bin_f);
}

/// Converts given FFT bin index to the corresponding frequency in Hz
pub fn binToFreq(sample_rate: usize, fft_size: usize, bin_index: usize) !f32 {
    const max_bin_index = binCount() - 1;

    if (bin_index > max_bin_index) {
        return error.OutOfRange;
    }

    const bin_f: f32 = @floatFromInt(bin_index);
    const bin_width = binWidth(sample_rate, fft_size);
    return bin_f * bin_width;
}

/// Loads samples into the KissFFT input buffer for forward FFT
fn loadSamplesFwd(
    self: *Self,
    samples: []const f32,
    window: []const f32,
) []const f32 {
    std.debug.assert(samples.len == window.len);

    for (0..samples.len) |i| {
        self.buf_real[i] = samples[i] * window[i];
    }

    return self.buf_real;
}

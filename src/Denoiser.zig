//! Wrapper around the RNNoise library:
//! 
//! * Implements C-to-Zig bindings
//! * Converts between normalized [-1, 1] float PCM samples and 
//!   format expected by RNNoise (`s16` values represented as floats)
//! * Accepts `SplitSlice(f32)` as input for better interop with 
//!   the rest of the program
//! 
const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitSlice = @import("./structures/SplitSlice.zig").SplitSlice;
const rnnoise = @cImport({
    @cInclude("rnnoise.h");
});

const Self = @This();

allocator: std.mem.Allocator,
denoise_state: ?*rnnoise.DenoiseState,

pub fn init(allocator: std.mem.Allocator) !Self {
    var denoise_state = rnnoise.rnnoise_create(null);

    return Self{
        .denoise_state = denoise_state,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    if (self.denoise_state != null) {
        rnnoise.rnnoise_destroy(self.denoise_state.?);
        self.denoise_state = null;
    }
}

/// Samples must be mono, *48kHz*, f32 values, normalized [-1, 1].
/// Returns a the VAD (voice activity detection) value and stores the denoised 
/// samples in `result`.
pub fn denoise(self: *Self, samples: SplitSlice(f32), result: []f32) !f32 {
    if (self.denoise_state == null) return error.NotInitialized;

    if (samples.len() != getFrameSize()) {
        return error.InvalidFrameSize;
    }

    if (result.len != samples.len()) {
        return error.InvalidResultSize;
    }

    const rnnoise_input = try self.allocator.alloc(f32, samples.len());
    defer self.allocator.free(rnnoise_input);

    // RNNoise expects an odd format, `s16` values represented as floats,
    // and we're working with normalized float PCM samples (`f32le` in `ffmpeg` terms)
    normalizedPcmToRnnoise(samples, rnnoise_input);

    const vad = rnnoise.rnnoise_process_frame(self.denoise_state.?, result.ptr, rnnoise_input.ptr);

    // Convert the output samples back to normalized float PCM
    rnnoiseToNormalizedPcm(result);

    return vad;
}

pub fn getFrameSize() usize {
    return @intCast(usize, rnnoise.rnnoise_get_frame_size());
}

const RNNOISE_NORM_SCALAR = @as(f32, std.math.maxInt(i16));
const RNNOISE_NORM_SCALAR_INVERSE = 1.0 / @as(f32, std.math.maxInt(i16));

/// Converts normalized [-1, 1] float PCM samples to the format
/// expected by RNNoise, `s16` values represented as floats
pub fn normalizedPcmToRnnoise(samples: SplitSlice(f32), result: []f32) void {
    for (0..samples.first.len) |idx| {
        result[idx] = samples.first[idx] * RNNOISE_NORM_SCALAR;
    }

    for (0..samples.second.len) |idx| {
        const offset_idx = idx + samples.first.len;
        result[offset_idx] = samples.second[idx] * RNNOISE_NORM_SCALAR;
    }
}

/// Converts RNNoise PCM format (`s16` as floats) format back to
/// normalized [-1, 1] float PCM samples
pub fn rnnoiseToNormalizedPcm(samples: []f32) void {
    for (samples) |*sample| {
        sample.* *= RNNOISE_NORM_SCALAR_INVERSE;
    }
}

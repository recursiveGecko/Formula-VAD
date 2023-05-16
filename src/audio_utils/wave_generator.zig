const std = @import("std");
const Allocator = std.mem.Allocator;
const pi = std.math.pi;

pub fn sine_wave(allocator: Allocator, amplitude: f32, samples: usize, frequency: f32, sample_rate: u32) ![]f32 {
    var waveform: []f32 = try allocator.alloc(f32, samples);
    errdefer allocator.free(waveform);

    const sample_rate_f = @intToFloat(f32, sample_rate);
    for (0..samples) |idx| {
        const i = @intToFloat(f32, idx);

        waveform[idx] = amplitude * @sin(2 * pi * frequency * i / sample_rate_f);
    }

    return waveform;
}


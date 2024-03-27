const std = @import("std");
const math = std.math;

/// Convert [0, 1] normalized values to dbFS
pub fn normToDBFS(values: []f32) void {
    const eps = std.math.f32_epsilon;
    for (values) |*value| {
        std.debug.assert(value.* < (1 + eps));
        value.* = 20.0 * std.math.log10(value.*);
    }
}

pub fn rmsVolume(samples: []const f32) f32 {
    var sum: f32 = 0.0;
    for (samples) |sample| {
        sum += sample * sample;
    }
    const mean = sum / @as(f32, @floatFromInt(samples.len));
    return math.sqrt(mean);
}

/// Converts time in seconds to sample number
pub fn secondsToSampleNumber(sec: f32, sample_rate: usize) u64 {
    const sample_rate_f: f32 = @floatFromInt(sample_rate);
    const sample_num_f = sample_rate_f * sec;
    return @intFromFloat(sample_num_f);
}

/// Converts sample number to time in seconds
pub fn sampleNumberToSeconds(sample_number: u64, sample_rate: usize) f32 {
    const sample_rate_f: f32 = @floatFromInt(sample_rate);
    const sample_num_f: f32 = @floatFromInt(sample_number);

    return sample_num_f / sample_rate_f;
}

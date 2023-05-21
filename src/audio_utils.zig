const std = @import("std");
const math = std.math;
const SplitSlice = @import("structures/SplitSlice.zig").SplitSlice;

/// Convert [0, 1] normalized values to dbFS
pub fn normToDBFS(values: []f32) void {
    const eps = std.math.f32_epsilon;
    for (values) |*value| {
        std.debug.assert(value.* < (1 + eps));
        value.* = 20.0 * std.math.log10(value.*);
    }
}

pub fn rmsVolume(samples: SplitSlice(f32)) f32 {
    var sum: f32 = 0.0;
    for (samples.first) |sample| {
        sum += sample * sample;
    }
    for (samples.second) |sample| {
        sum += sample * sample;
    }
    const mean = sum / @intToFloat(f32, samples.len());
    return math.sqrt(mean);
}

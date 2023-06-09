const std = @import("std");
const SplitSlice = @import("../structures/SplitSlice.zig").SplitSlice;

pub fn calcDownsampleRate(in_sample_rate: usize, base_rate: usize) usize {
    if (in_sample_rate % base_rate != 0) @panic("Invalid sample rate - must be divisible by base_rate");
    return in_sample_rate / base_rate;
}

pub fn downsampleAudio(
    input_samples: SplitSlice(f32),
    output_samples: []f32,
    downsample_rate: usize,
) void {
    if (input_samples.len() != output_samples.len * downsample_rate) {
        @panic("Invalid downsampling inputs");
    }

    const n_steps = input_samples.len() / downsample_rate;

    for (0..n_steps) |i| {
        const src_idx = i * downsample_rate;

        if (src_idx < input_samples.first.len) {
            output_samples[i] = input_samples.first[src_idx];
        } else if (src_idx >= input_samples.first.len) {
            output_samples[i] = input_samples.second[src_idx - input_samples.first.len];
        }
    }
}

// FIXME: upsampling could use a better algorithm
pub fn upsampleAudio(
    input_samples: []f32,
    output_samples: []f32,
    upsample_rate: usize,
) void {
    if (input_samples.len * upsample_rate != output_samples.len) {
        @panic("Invalid upsampling inputs");
    }

    const n_steps = input_samples.len;

    for (0..n_steps) |i| {
        const dst_idx = i * upsample_rate;

        output_samples[dst_idx] = input_samples[i];
        if (i + 1 == n_steps) return;

        const curr = input_samples[i];
        const next = input_samples[i + 1];

        output_samples[dst_idx + 1] = std.math.lerp(curr, next, 1.0 / 3.0);
        output_samples[dst_idx + 2] = std.math.lerp(curr, next, 2.0 / 3.0);
    }
}

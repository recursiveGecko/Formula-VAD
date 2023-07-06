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
    prev_last_sample: f32,
    upsample_rate: usize,
) f32 {
    if (input_samples.len * upsample_rate != output_samples.len) {
        @panic("Invalid upsampling inputs");
    }

    const n_interpolate = upsample_rate - 1;

    // 1:3 upsampling -> [interp1, interp2, first, ...]
    interpolate(prev_last_sample, input_samples[0], output_samples[0..n_interpolate]);
    output_samples[n_interpolate] = input_samples[0];

    var last_sample = input_samples[0];

    for (1..input_samples.len) |i| {
        const prev_in = input_samples[i - 1];
        const curr_in = input_samples[i];

        const interp_from = i * upsample_rate;
        const interp_to = interp_from + n_interpolate;
        const interp_dst = output_samples[interp_from..interp_to];

        interpolate(prev_in, curr_in, interp_dst);
        output_samples[interp_to] = curr_in;

        last_sample = curr_in;
    }

    return last_sample;
}

pub inline fn interpolate(
    first: f32,
    second: f32,
    dest: []f32,
) void {
    for (0..dest.len) |i| {
        const fill_idx_f: f32 = @floatFromInt(i + 1);
        const fill_count_f: f32 = @floatFromInt(dest.len + 1);
        const frac = fill_idx_f / fill_count_f;

        dest[i] = std.math.lerp(first, second, frac);
    }
}

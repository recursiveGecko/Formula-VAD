const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioPipeline = @import("../AudioPipeline.zig");
const AudioBuffer = @import("../audio_utils/AudioBuffer.zig");

pub fn runVADSingle(allocator: Allocator, file: AudioBuffer) !void {
    const pipeline = try AudioPipeline.init(allocator, .{
        .sample_rate = file.sample_rate,
        .n_channels = file.n_channels,
    });
    defer pipeline.deinit();

    const frame_size = 2048;
    const steps = file.length / frame_size + @boolToInt(file.length % frame_size != 0);

    var framed_channel_pcm = try allocator.alloc([]f32, file.n_channels);
    defer allocator.free(framed_channel_pcm);

    for (0..steps) |step_idx| {
        const from = step_idx * frame_size;
        const to = @min(file.length, from + frame_size);

        for (0..file.n_channels) |channel_idx| {
            framed_channel_pcm[channel_idx] = file.channel_pcm_buf[channel_idx][from..to];
        }

        try pipeline.pushSamples(framed_channel_pcm);
    }
}

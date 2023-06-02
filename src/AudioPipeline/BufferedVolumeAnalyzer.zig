const std = @import("std");
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");
const VADMetadata = @import("./VADMetadata.zig");
const BufferedStep = @import("./BufferedStep.zig");
const audio_utils = @import("../audio_utils.zig");

pub const VolumeAnalysis = struct {
    volume_ratio: f32,
    volume_min: f32,
    volume_max: f32,
};

const Self = @This();

allocator: Allocator,
vad_metadata: VADMetadata = .{},

pub fn init(allocator: Allocator) !Self {
    return Self{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn write(
    self: *Self,
    input: *const BufferedStep.Result,
) BufferedStep.Result {
    var volume_analysis = analyseVolume(input.segment);

    self.vad_metadata.push(
        volume_analysis,
        input.segment.length,
    );

    const result = BufferedStep.Result{
        .segment = input.segment,
        .metadata = self.vad_metadata.toResult(),
    };

    self.vad_metadata = .{};
    return result;
}
pub fn analyseVolume(input_segment: *const Segment) VolumeAnalysis {
    const n_channels = input_segment.channel_pcm_buf.len;

    // Find the volume ratio between channels
    var vol_min: f32 = 1;
    var vol_max: f32 = 0;
    for (0..n_channels) |channel_idx| {
        var channel_slice = input_segment.channel_pcm_buf[channel_idx];
        var vol = audio_utils.rmsVolume(channel_slice);

        if (vol < vol_min) vol_min = vol;
        if (vol > vol_max) vol_max = vol;
    }

    const vol_ratio: f32 = if (vol_max == 0) 0 else vol_min / vol_max;

    return VolumeAnalysis{
        .volume_ratio = vol_ratio,
        .volume_min = vol_min,
        .volume_max = vol_max,
    };
}

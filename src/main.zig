const std = @import("std");
const Allocator = std.mem.Allocator;
const ingress = @import("./ingress.zig");
pub const AudioPipeline = @import("./AudioPipeline.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // try audioTest(allocator);
    try ingress.start(allocator);
}

pub fn audioTest(allocator: Allocator) !void {
    _ = allocator;

    // const Spectrogram = @import("./audio_utils/Spectrogram.zig");
    // const spectrogram = try Spectrogram.compute(allocator, audio.channel_pcm_buf[0], .{
    //     .sample_rate = audio.sample_rate,
    // });

    // const gui = @import("./gui.zig");
    // try gui.visualizeSpectrogram(allocator, spectrogram);
}

test {
    _ = AudioPipeline;
    _ = @import("./structures/MultiRingBuffer.zig");
}

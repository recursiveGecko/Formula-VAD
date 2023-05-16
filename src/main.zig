const std = @import("std");
const Allocator = std.mem.Allocator;
const ingress = @import("./ingress.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();

    // try audioTest(allocator);
    try ingress.start(allocator);
}

pub fn audioTest(allocator: Allocator) !void {
    const AudioBuffer = @import("./audio_utils/AudioBuffer.zig");
    // const audio = try AudioBuffer.loadFromFile(allocator, "tmp/dtfm.ogg");
    const audio = try AudioBuffer.loadFromFile(allocator, "tmp/increasing.ogg");
    std.debug.print("Loaded audio file\n", .{});

    const batch_vad = @import("./cli/batch-vad.zig");
    try batch_vad.runVADSingle(allocator, audio);

    // const repeats = (60) / (audio.length / audio.sample_rate);
    // std.debug.print("Repeating: {d} times, total samples: {d}\n", .{repeats, repeats * audio.length});
    // for (1..repeats) |_| {
    //     try batch_vad.runVADSingle(allocator, audio);
    // }

    // const Spectrogram = @import("./audio_utils/Spectrogram.zig");
    // const spectrogram = try Spectrogram.compute(allocator, audio.channel_pcm_buf[0], .{
    //     .sample_rate = audio.sample_rate,
    // });

    // const gui = @import("./gui.zig");
    // try gui.visualizeSpectrogram(allocator, spectrogram);
}

test {
    _ = @import("./AudioPipeline.zig");
    _ = @import("./structures/FixedCapacityDeque.zig");
}

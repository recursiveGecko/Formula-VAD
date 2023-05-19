const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const AudioFileStream = @import("AudioFileStream.zig");
const Self = @This();

allocator: Allocator,
n_channels: usize,
sample_rate: usize,
channel_pcm_buf: [][]f32,
length: usize,
duration_seconds: f32,

pub fn loadFromFile(allocator: Allocator, path: []const u8) !Self {
    var stream = try AudioFileStream.open(allocator, path);
    defer stream.close();

    var channel_pcm_buf = try allocator.alloc([]f32, stream.n_channels);
    var channels_allocated: usize = 0;
    errdefer {
        for (0..channels_allocated) |i| allocator.free(channel_pcm_buf[i]);
        allocator.free(channel_pcm_buf);
    }

    for (0..stream.n_channels) |i| {
        channel_pcm_buf[i] = try allocator.alloc(f32, stream.length);
        channels_allocated += 1;
    }

    const read_chunk_size = stream.sample_rate * 10;
    var offset: usize = 0;
    while (true) {
        const samples_read = try stream.read(channel_pcm_buf, offset, read_chunk_size);
        if (samples_read < read_chunk_size) break;
        offset += samples_read;
    }

    return Self{
        .allocator = allocator,
        .n_channels = stream.n_channels,
        .sample_rate = stream.sample_rate,
        .channel_pcm_buf = channel_pcm_buf,
        .length = stream.length,
        .duration_seconds = @intToFloat(f32, stream.length) / @intToFloat(f32, stream.sample_rate),
    };
}

pub fn deinit(self: *Self) void {
    for (self.channel_pcm_buf) |chan_buf| self.allocator.free(chan_buf);
    self.allocator.free(self.channel_pcm_buf);
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sndfile = @cImport({
    @cInclude("sndfile.h");
});

const Self = @This();

allocator: Allocator,
n_channels: usize,
sample_rate: usize,
channel_pcm_buf: [][]f32,
raw_pcm_buf: []f32,
// in samples
length: usize,

pub fn loadFromFile(allocator: Allocator, path: [:0]const u8) !Self {
    var info: sndfile.SF_INFO = std.mem.zeroInit(sndfile.SF_INFO, .{});
    var file = sndfile.sf_open(path.ptr, sndfile.SFM_READ, &info);

    if (file == null) {
        return error.SndfileOpenError;
    }
    defer _ = sndfile.sf_close(file);

    const n_channels = @intCast(usize, info.channels);
    const sample_rate = @intCast(usize, info.samplerate);
    const length = @intCast(usize, info.frames);

    var raw_pcm_buf = try allocator.alloc(f32, n_channels * length);
    errdefer allocator.free(raw_pcm_buf);

    var channel_pcm_buf = try allocator.alloc([]f32, n_channels);
    errdefer allocator.free(channel_pcm_buf);

    for (channel_pcm_buf, 0..) |*channel_pcm, idx| {
        const from = idx * length;
        const to = from + length;
        channel_pcm.* = raw_pcm_buf[from..to];
    }

    // Read file in 1 second chunks
    const read_chunk_size = n_channels * sample_rate;
    var interleaved_frames = try allocator.alloc(f32, read_chunk_size);
    defer allocator.free(interleaved_frames);

    var sample_index: usize = 0;
    while (true) {
        const c_items_read = sndfile.sf_read_float(file, interleaved_frames.ptr, @intCast(i64, read_chunk_size));
        const items_read = @intCast(usize, c_items_read);

        for (0..items_read) |i| {
            const channel_idx = i % n_channels;
            channel_pcm_buf[channel_idx][sample_index] = interleaved_frames[i];

            if (i % n_channels == n_channels - 1) sample_index += 1;
        }

        if (items_read < read_chunk_size) {
            break;
        }
    }

    return Self{
        .allocator = allocator,
        .n_channels = n_channels,
        .sample_rate = sample_rate,
        .channel_pcm_buf = channel_pcm_buf,
        .raw_pcm_buf = raw_pcm_buf,
        .length = length,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.channel_pcm_buf);
    self.allocator.free(self.raw_pcm_buf);
}

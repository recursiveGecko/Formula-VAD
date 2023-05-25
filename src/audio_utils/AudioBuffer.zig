const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const AudioFileStream = @import("AudioFileStream.zig");
const sndfile = @cImport({
    @cInclude("sndfile.h");
});

const Self = @This();

pub const Format = enum(u32) {
    vorbis = sndfile.SF_FORMAT_OGG | sndfile.SF_FORMAT_VORBIS,
    wav = sndfile.SF_FORMAT_WAV | sndfile.SF_FORMAT_FLOAT,
};

allocator: Allocator,
n_channels: usize,
sample_rate: usize,
channel_pcm_buf: [][]f32,
length: usize,
duration_seconds: f32,
/// If the AudioBuffer was cut from a larger context (e.g. AudioPipeline),
/// this is the frame number of the first frame in the original context.
global_start_frame_number: ?u64 = null,

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

pub fn saveToFile(self: *const Self, path: []const u8, format: Format) !void {
    const path_Z = try self.allocator.dupeZ(u8, path);
    defer self.allocator.free(path_Z);

    var sf_info = std.mem.zeroInit(sndfile.SF_INFO, .{
        .samplerate = @intCast(i32, self.sample_rate),
        .channels = @intCast(i32, self.n_channels),
        .format = @intCast(i32, @enumToInt(format)),
    });

    var sf_file = sndfile.sf_open(path_Z.ptr, sndfile.SFM_WRITE, &sf_info);
    defer _ = sndfile.sf_close(sf_file);

    if (format == .vorbis) {
        var quality: f64 = 1;
        var cmd_resut = sndfile.sf_command(sf_file, sndfile.SFC_SET_VBR_ENCODING_QUALITY, &quality, @sizeOf(f64));
        assert(cmd_resut == 1);
    }

    const frames_per_write = self.sample_rate;
    var write_buffer = try self.allocator.alloc(f32, self.n_channels * frames_per_write);
    defer self.allocator.free(write_buffer);

    var frames_read_count: usize = 0;
    while (frames_read_count < self.length) {
        const frames_to_write = @min(self.length - frames_read_count, frames_per_write);

        for (0..frames_to_write) |frame_idx| {
            const read_idx = frames_read_count + frame_idx;

            for (0..self.n_channels) |channel_idx| {
                const write_idx = frame_idx * self.n_channels + channel_idx;

                write_buffer[write_idx] = self.channel_pcm_buf[channel_idx][read_idx];
            }
        }

        const frames_written = sndfile.sf_writef_float(sf_file, write_buffer.ptr, @intCast(i64, frames_to_write));
        assert(frames_written == frames_to_write);

        frames_read_count += @intCast(usize, frames_written);
    }
}

pub fn deinit(self: *Self) void {
    for (self.channel_pcm_buf) |chan_buf| self.allocator.free(chan_buf);
    self.allocator.free(self.channel_pcm_buf);
}

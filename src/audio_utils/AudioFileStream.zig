const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sndfile = @cImport({
    @cInclude("sndfile.h");
});

const Self = @This();

allocator: Allocator,
sf_info: sndfile.SF_INFO,
sf_file: ?*sndfile.SNDFILE,
n_channels: usize,
sample_rate: usize,
length: usize,

pub fn open(allocator: Allocator, path: []const u8) !Self {
    var self = Self{
        .allocator = allocator,
        .sf_info = std.mem.zeroInit(sndfile.SF_INFO, .{}),
        .sf_file = null,
        .n_channels = undefined,
        .sample_rate = undefined,
        .length = undefined,
    };
    errdefer self.close();

    const path_Z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_Z);

    self.sf_file = sndfile.sf_open(path_Z.ptr, sndfile.SFM_READ, &self.sf_info);

    if (self.sf_file == null) {
        return error.SndfileOpenError;
    }

    self.n_channels = @intCast(usize, self.sf_info.channels);
    self.sample_rate = @intCast(usize, self.sf_info.samplerate);
    self.length = @intCast(usize, self.sf_info.frames);

    return self;
}

/// Reads a given maximum number of samples from the file and writes them into
/// the given destination buffer, starting at the given offset.
/// Returns the number of samples read.
/// Returns an error if the destination is full, callers should close the stream
/// when the number of samples read is less than the number of samples expected.
/// The caller must provide a temporary buffer that samples will be read into
/// before they are deinterleaved into the destination buffer. Buffer must be
/// `max_samples` * `n_channels` in length.
///
pub fn read(self: *Self, interleaved_buffer: []f32, result_pcm: [][]f32, offset: usize, max_samples: usize) !usize {
    if (self.sf_file == null) {
        return error.FileNotOpen;
    }
    const sf_file = self.sf_file.?;

    assert(result_pcm.len == self.n_channels);

    const rem_result_size = result_pcm[0].len - offset;
    const n_samples = @min(max_samples, rem_result_size);
    const read_chunk_size = self.n_channels * n_samples;

    if (rem_result_size == 0) {
        return error.DestinationBufferFull;
    }

    // Read samples into the interleaved buffer
    const c_samples_read = sndfile.sf_read_float(sf_file, interleaved_buffer.ptr, @intCast(i64, read_chunk_size));
    const samples_read = @intCast(usize, c_samples_read);

    // Organize samples into separated channel buffers
    var sample_index: isize = @intCast(isize, offset) - 1;
    for (0..samples_read) |i| {
        const channel_idx = i % self.n_channels;
        if (channel_idx == 0) sample_index += 1;

        result_pcm[channel_idx][@intCast(usize, sample_index)] = interleaved_buffer[i];
    }

    return samples_read / self.n_channels;
}

pub fn seekToSample(self: *Self, sample: usize) !void {
    if (self.sf_file == null) {
        return error.FileNotOpen;
    }

    const sf_file = self.sf_file.?;

    const c_sample_index = @intCast(i64, sample);
    const c_seek_result = sndfile.sf_seek(sf_file, c_sample_index, sndfile.SEEK_SET);

    if (c_seek_result == -1) {
        return error.SeekFailed;
    }
}

pub fn close(self: *Self) void {
    if (self.sf_file) |sf_file| {
        _ = sndfile.sf_close(sf_file);
        self.sf_file = null;
    }
}

pub fn durationSeconds(self: Self) f32 {
    return @intToFloat(f32, self.length) / @intToFloat(f32, self.sample_rate);
}

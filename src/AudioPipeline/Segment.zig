//! `Segment` is a container for multiple channels of audio data.
//!
//! Each audio channel is represented by a slice of `f32` samples.
//!
//! Each segment has an `index`, which corresponds to the index of the first sample
//! in the segment. This index combined with the sample rate, can be used to calculate
//! precise timestamps for the samples in the segment, relative to the beginning of the
//! AudioPipeline. Every step in the pipeline is responsible for keeping this index
//! accurate when slicing or combining segments.
//!

const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioBuffer = @import("../audio_utils/AudioBuffer.zig");

const Self = @This();

/// The index/sample number of the first sample in the segment
index: u64,
allocator: ?Allocator = null,
/// Per-channel audio data.
channel_pcm_buf: [][]f32,
is_view: bool = false,

pub fn initWithCapacity(allocator: Allocator, n_channels: usize, init_length: usize) !Self {
    var channel_pcm_buf = try allocator.alloc([]f32, n_channels);
    var n_initialized: usize = 0;
    errdefer {
        for (0..n_initialized) |i| {
            allocator.free(channel_pcm_buf[i]);
        }
        allocator.free(channel_pcm_buf);
    }

    for (0..n_channels) |i| {
        channel_pcm_buf[i] = try allocator.alloc(f32, init_length);
        n_initialized += 1;
    }

    const self = Self{
        .index = 0,
        .allocator = allocator,
        .channel_pcm_buf = channel_pcm_buf,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.allocator) |allocator| {
        for (0..self.nChannels()) |i| {
            allocator.free(self.channel_pcm_buf[i]);
        }

        allocator.free(self.channel_pcm_buf);
    }
}

pub fn length(self: *const Self) usize {
    return self.channel_pcm_buf[0].len;
}

pub fn nChannels(self: *const Self) usize {
    return self.channel_pcm_buf.len;
}

/// Creates a *deep copy* of the Segment.
pub fn copy(self: *const Self, allocator: Allocator) !Self {
    const new_self = try self.copyCapacity(allocator);

    for (0..self.channel_pcm_buf.len) |i| {
        @memcpy(new_self.channel_pcm_buf[i], self.channel_pcm_buf[i]);
    }

    return new_self;
}

/// Copies the shape and capacity of the original, but not the contents.
pub fn copyCapacity(self: *const Self, allocator: Allocator) !Self {
    var channel_pcm = try allocator.alloc([]f32, self.channel_pcm_buf.len);
    var copied: usize = 0;
    errdefer {
        for (0..copied) |i| {
            allocator.free(channel_pcm[i]);
        }
        allocator.free(channel_pcm);
    }

    for (0..self.channel_pcm_buf.len) |i| {
        channel_pcm[i] = try allocator.alloc(f32, self.length());
        copied += 1;
    }

    const new_self = Self{
        .index = self.index,
        .allocator = allocator,
        .channel_pcm_buf = channel_pcm,
    };

    return new_self;
}

pub fn resize(self: *Self, new_size: usize) !void {
    if (self.allocator == null) return error.NotResizeable;
    if (self.is_view) @panic("Segment view has an allocator that shouldn't exist.");

    const alloc = self.allocator.?;

    // This could be problematic if some of the resize operations fail.
    for (0..self.channel_pcm_buf.len) |i| {
        const src_channel = self.channel_pcm_buf[i];
        const resized = alloc.resize(src_channel, new_size);

        if (!resized) {
            const copy_len = @min(new_size, src_channel.len);
            const dst_channel = try alloc.alloc(f32, new_size);

            @memcpy(dst_channel[0..copy_len], src_channel[0..copy_len]);
            alloc.free(src_channel);
            self.channel_pcm_buf[i] = dst_channel;
        }

        std.debug.assert(self.channel_pcm_buf[i].len == new_size);
    }
}

pub fn clipView(self: *const Self, from: usize, to: usize) !void {
    if (!self.is_view) return error.NotAView;
    if (self.allocator != null) @panic("Segment view has an allocator that shouldn't exist.");

    for (0..self.nChannels()) |i| {
        self.channel_pcm_buf[i] = self.channel_pcm_buf[i][from..to];
    }
}

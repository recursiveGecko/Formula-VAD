//! `Segment` is a container for multiple channels of audio data.
//!
//! Each audio channel is represented by a `SplitSlice` of `f32` samples, which allows
//! us to wrap non-contiguous audio samples (e.g. originating from a ring buffer) in
//! a single struct without creating a copy.
//!
//! Each segment has an `index`, which corresponds to the index of the first sample
//! in the segment. This index combined with the sample rate, can be used to calculate
//! precise timestamps for the samples in the segment, relative to the beginning of the
//! AudioPipeline. Every step in the pipeline is responsible for keeping this index
//! accurate when slicing or combining segments.
//!

const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitSlice = @import("../structures/SplitSlice.zig").SplitSlice;
const AudioBuffer = @import("../audio_utils/AudioBuffer.zig");

const Self = @This();

/// The index/sample number of the first sample in the segment relative to the start of the pipeline.
index: u64,
/// The number of samples in the segment.
length: usize,
allocator: ?Allocator,
/// Per-channel audio data.
channel_pcm_buf: []SplitSlice(f32),

pub fn initWithCapacity(allocator: Allocator, n_channels: usize, length: usize) !Self {
    var channel_pcm_buf_ = try allocator.alloc(SplitSlice(f32), n_channels);
    var chan_initialized: usize = 0;
    errdefer {
        for (0..chan_initialized) |i| {
            channel_pcm_buf_[i].deinit();
        }
        allocator.free(channel_pcm_buf_);
    }

    for (0..n_channels) |i| {
        channel_pcm_buf_[i] = try SplitSlice(f32).initWithCapacity(allocator, length);
        chan_initialized += 1;
    }

    var self = Self{
        .index = undefined,
        .length = length,
        .allocator = allocator,
        .channel_pcm_buf = channel_pcm_buf_,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    for (self.channel_pcm_buf) |*channel_pcm| {
        channel_pcm.deinit();
    }

    if (self.allocator) |allocator| {
        allocator.free(self.channel_pcm_buf);
    }
}

/// Creates a *deep copy* of the Segment.
/// SplitSlice shape is not copied exactly, instead both halves
/// are merged into `.first` half of the slice.
pub fn copy(self: *Self, allocator: Allocator) !Self {
    var channel_pcm_copy = try allocator.alloc(SplitSlice(f32), self.channel_pcm_buf.len);
    var copied: usize = 0;
    errdefer {
        for (0..copied) |i| {
            channel_pcm_copy[i].deinit();
        }
        allocator.free(channel_pcm_copy);
    }

    for (0..self.channel_pcm_buf.len) |i| {
        channel_pcm_copy[i] = try self.channel_pcm_buf[i].copy(allocator);
        copied += 1;
    }

    var new_self = Self{
        .index = self.index,
        .length = self.length,
        .allocator = allocator,
        .channel_pcm_buf = channel_pcm_copy,
    };

    return new_self;
}

/// Copies the shape and capacity of the original, but not the contents.
/// SplitSlice shape is not copied exactly, instead both halves of the
/// split slice are merged into `.first` half of the slice.
pub fn copyCapacity(self: *Self, allocator: Allocator) !Self {
    var channel_pcm = try allocator.alloc(SplitSlice(f32), self.channel_pcm_buf.len);
    var copied: usize = 0;
    errdefer {
        for (0..copied) |i| {
            channel_pcm[i].deinit();
        }
        allocator.free(channel_pcm);
    }

    for (0..self.channel_pcm_buf.len) |i| {
        channel_pcm[i] = try self.channel_pcm_buf[i].copyCapacity(allocator);
        copied += 1;
    }

    var new_self = Self{
        .index = self.index,
        .length = self.length,
        .allocator = allocator,
        .channel_pcm_buf = channel_pcm,
    };

    return new_self;
}

pub fn resize(self: *Self, new_size: usize) !void {
    // This could be problematic if some of the resize operations fail.
    for (self.channel_pcm_buf) |*channel| {
        try channel.resize(new_size, 0);
    }
    
    self.length = new_size;
}

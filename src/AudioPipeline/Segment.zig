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

const ReadOnlyChannelPCM = []const []const f32;
const WritableChannelPCM = [][]f32;
const SliceableChannelPCM = [][]const f32;

/// The index/sample number of the first sample in the segment
index: u64,
allocator: ?Allocator = null,
/// Per-channel audio data.
channel_pcm_buf: ReadOnlyChannelPCM,
/// If the segment owns everything, then all operations are permitted,
/// if the segment owns the channels, then its samples must not be mutated, but channels can be sliced
/// if the segment owns nothing, then no modifications are permitted
mem_ownership: enum { nothing, channels, everything },

/// Initialize a Segment that owns the channel slice, but not the samples.
/// Useful for zero-copy views.
pub fn initWithChannels(allocator: Allocator, n_channels: usize) !Self {
    const channel_pcm_buf = try allocator.alloc([]f32, n_channels);

    const self = Self{
        .index = 0,
        .allocator = allocator,
        .channel_pcm_buf = channel_pcm_buf,
        .mem_ownership = .channels,
    };

    return self;
}

pub fn initWithCapacity(allocator: Allocator, n_channels: usize, init_length: usize) !Self {
    var self = try initWithChannels(allocator, n_channels);
    var n_initialized: usize = 0;
    errdefer {
        for (0..n_initialized) |i| {
            allocator.free(self.channel_pcm_buf[i]);
        }
        self.deinit();
    }

    const channel_pcm_buf: SliceableChannelPCM = self.sliceablePCM();
    for (0..n_channels) |i| {
        channel_pcm_buf[i] = try allocator.alloc(f32, init_length);
        n_initialized += 1;
    }

    self.mem_ownership = .everything;

    return self;
}

/// Returns the PCM buffer with all write restrictions removed. Allows slicing and data modification.
/// Checks whether the Segment owns the underlying samples.
pub fn writablePCM(self: *Self) WritableChannelPCM {
    if (self.mem_ownership != .everything) @panic("Requested full access to Segment which doesn't own undelying samples");
    const ptr: *WritableChannelPCM = @ptrCast(&self.channel_pcm_buf);
    return ptr.*;
}

/// Returns the PCM buffer with some write restrictions removed. Allows slicing but not data modification.
/// Checks whether the Segment owns the channel slice.
pub fn sliceablePCM(self: *Self) SliceableChannelPCM {
    if (self.mem_ownership == .nothing) @panic("Requested slice access to Segment which doesn't own its channels");
    const ptr: *SliceableChannelPCM = @ptrCast(&self.channel_pcm_buf);
    return ptr.*;
}

pub fn deinit(self: *Self) void {
    if (self.mem_ownership != .nothing and self.allocator == null) @panic("Segment owns memory but is it's missing an allocator");
    if (self.mem_ownership == .nothing and self.allocator != null) @panic("Segment doesn't own memory but it has an allocator");

    switch (self.mem_ownership) {
        .everything => {
            for (0..self.nChannels()) |i| {
                self.allocator.?.free(self.channel_pcm_buf[i]);
            }
            self.allocator.?.free(self.channel_pcm_buf);
        },
        .channels => {
            self.allocator.?.free(self.channel_pcm_buf);
        },
        .nothing => {},
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
        .mem_ownership = .everything,
    };

    return new_self;
}

pub fn resize(self: *Self, new_size: usize) !void {
    const channel_pcm_buf = self.writablePCM();
    // If the Segment is writable, we must have an allocator
    const alloc = self.allocator.?;

    // This could be problematic if some of the resize operations fail.
    for (0..self.channel_pcm_buf.len) |i| {
        const src_channel = channel_pcm_buf[i];
        const resized = alloc.resize(src_channel, new_size);

        if (!resized) {
            const copy_len = @min(new_size, src_channel.len);
            const dst_channel = try alloc.alloc(f32, new_size);

            @memcpy(dst_channel[0..copy_len], src_channel[0..copy_len]);
            alloc.free(src_channel);
            channel_pcm_buf[i] = dst_channel;
        }

        std.debug.assert(self.channel_pcm_buf[i].len == new_size);
    }
}

pub fn clipView(self: *Self, from: usize, to: usize) !void {
    if (self.mem_ownership != .channels) @panic("clipView() used on a Segment that is not a view");

    const channel_pcm_buf = self.sliceablePCM();
    for (0..self.nChannels()) |i| {
        channel_pcm_buf[i] = channel_pcm_buf[i][from..to];
    }
}

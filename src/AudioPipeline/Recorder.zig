const std = @import("std");
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const SplitSlice = @import("../structures/SplitSlice.zig").SplitSlice;
const AudioBuffer = @import("../audio_utils/AudioBuffer.zig");

const Self = @This();

allocator: Allocator,
n_channels: usize,
sample_rate: usize,
status: enum { idle, recording } = .idle,
segment_writer: SegmentWriter,
last_recording_end_index: u64 = 0,

pub fn init(allocator: Allocator, n_channels: usize, sample_rate: usize) !Self {
    var self = Self{
        .allocator = allocator,
        .n_channels = n_channels,
        .sample_rate = sample_rate,
        .segment_writer = undefined,
    };

    try self.allocNewWriter();
    return self;
}

pub fn deinit(self: *Self) void {
    self.segment_writer.deinit();
}

pub fn isRecording(self: Self) bool {
    return self.status == .recording;
}

pub fn currentCapacity(self: Self) usize {
    return self.segment_writer.segment.length;
}

/// Index of the first saved frame (sample) in the recording
pub fn startIndex(self: Self) u64 {
    return self.segment_writer.segment.index;
}

/// Index following the last saved frame (sample) in the recording
pub fn endIndex(self: Self) u64 {
    return self.segment_writer.segment.index + self.segment_writer.write_index;
}

pub fn start(self: *Self, start_index: u64) void {
    self.segment_writer.segment.index = start_index;
    self.segment_writer.write_index = 0;
    self.status = .recording;
}

pub fn write(self: *Self, segment: *const Segment) !void {
    const required_length = self.segment_writer.write_index + segment.length;

    if (required_length > self.currentCapacity()) {
        // When resizing, add at least 10 seconds worth of samples to the current capacity.
        const new_length = @max(required_length, self.currentCapacity() + self.sample_rate * 10);
        try self.segment_writer.resize(new_length);
    }

    const written = try self.segment_writer.write(segment, 0, null);
    std.debug.assert(written == segment.length);
}

pub fn finalize(self: *Self, to_frame: u64, keep: bool) !?AudioBuffer {
    self.status = .idle;
    defer self.segment_writer.write_index = 0;

    if (keep) {
        // Data needs to be written before finalize() is called.
        if (to_frame < self.endIndex()) return error.MissingData;

        const n_to_keep = to_frame - self.startIndex();
        try self.segment_writer.resize(n_to_keep);

        const segment = self.segment_writer.segment;
        try self.allocNewWriter();
        
        var audio_buffer = try segmentToAudioBuffer(segment, self.sample_rate);

        self.last_recording_end_index = to_frame;
        return audio_buffer;
    } else {
        // If we're not keeping the data, we can just reset the write index.
        return null;
    }
}

fn segmentToAudioBuffer(segment: Segment, sample_rate: usize) !AudioBuffer {
    defer segment.allocator.?.free(segment.channel_pcm_buf);

    const allocator = segment.allocator.?;
    const n_channels = segment.channel_pcm_buf.len;

    var channel_pcm_buf = try allocator.alloc([]f32, n_channels);
    errdefer allocator.free(channel_pcm_buf);

    for (0..n_channels) |i| {
        std.debug.assert(segment.channel_pcm_buf[i].first.len == segment.length);
        std.debug.assert(segment.channel_pcm_buf[i].second.len == 0);
        channel_pcm_buf[i] = segment.channel_pcm_buf[i].first;
    }

    var audio_buffer = AudioBuffer {
        .allocator = allocator,
        .length = segment.length,
        .sample_rate = sample_rate,
        .n_channels = n_channels,
        .duration_seconds = @intToFloat(f32, segment.length) / @intToFloat(f32, sample_rate),
        .channel_pcm_buf = channel_pcm_buf,
    };

    return audio_buffer;
}

fn allocNewWriter(self: *Self) !void {
    const initial_length = self.sample_rate * 10;

    const segment_writer = try SegmentWriter.init(self.allocator, self.n_channels, initial_length);
    self.segment_writer = segment_writer;
}

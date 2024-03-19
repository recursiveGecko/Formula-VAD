//! SegmentWriter can pack multiple segments into a single, larger
//! segment or split larger segments into multiple smaller segments.
//! This is useful for stages of the audio pipeline that need to
//! operate on different segment sizes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");

const Self = @This();

allocator: Allocator,
write_index: usize = 0,
// holds actual data
internal_segment: Segment,
// holds read-only view into written data
segment_view: Segment,

pub fn init(
    allocator: Allocator,
    n_channels: usize,
    length: usize,
) !Self {
    var internal_segment = try Segment.initWithCapacity(allocator, n_channels, length);
    errdefer internal_segment.deinit();

    var segment_view = try Segment.initWithChannels(allocator, n_channels);
    errdefer segment_view.deinit();

    const self = Self{
        .allocator = allocator,
        .internal_segment = internal_segment,
        .segment_view = segment_view,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    self.segment_view.deinit();
    self.internal_segment.deinit();
}

pub fn isFull(self: *Self) bool {
    return self.write_index == self.internal_segment.length();
}

/// Writes the given segment to the buffer, returning the number of samples written.
/// When the return value is less than the length of the source buffer, it means that
/// the buffer is full and the buffer segment should be used in some way before
/// calling .reset(), followed by a second .write() with the offset returned from this call.
pub fn write(self: *Self, source: *const Segment, read_offset: usize) !usize {
    var segment = self.internal_segment;

    // Determine the capacity of the internal buffer
    const capacity = segment.length();
    const remaining_capacity = capacity - @min(self.write_index, capacity);

    if (remaining_capacity == 0) {
        return 0;
    }

    // number of samples the caller is asking us to write
    const n_samples_in_source = source.length() - read_offset;

    // number of source samples we can actually write before we fill the buffer
    const n_samples_to_write = @min(remaining_capacity, n_samples_in_source);

    // Ensure the number of channels match
    if (segment.channel_pcm_buf.len != source.channel_pcm_buf.len) {
        return error.ChannelCountMismatch;
    }

    const n_channels = segment.channel_pcm_buf.len;

    for (0..n_channels) |chan_idx| {
        // slices of each channel
        var dst_chan = segment.writablePCM()[chan_idx];
        var src_chan = source.channel_pcm_buf[chan_idx];

        @memcpy(
            dst_chan[self.write_index .. self.write_index + n_samples_to_write],
            src_chan[read_offset .. read_offset + n_samples_to_write],
        );
    }

    self.write_index += n_samples_to_write;
    self.updateReadOnlyView();

    return n_samples_to_write;
}

pub fn reset(self: *Self, new_segment_index: u64) void {
    self.write_index = 0;
    self.internal_segment.index = new_segment_index;
    self.updateReadOnlyView();
}

pub fn resize(self: *Self, new_size: usize) !void {
    try self.internal_segment.resize(new_size);
    self.updateReadOnlyView();
}

fn updateReadOnlyView(self: *Self) void {
    self.segment_view.index = self.internal_segment.index;

    for (0..self.internal_segment.nChannels()) |i| {
        const src_channel = self.internal_segment.channel_pcm_buf[i];
        self.segment_view.sliceablePCM()[i] = src_channel[0..self.write_index];
    }
}

//
// Tests
//

test "SegmentWriter" {
    const t = std.testing;

    var segment_writer = try init(t.allocator, 1, 10);
    defer segment_writer.deinit();

    var segment = try Segment.initWithCapacity(t.allocator, 1, 4);
    defer segment.deinit();

    @memcpy(segment.writablePCM()[0], &[_]f32{ 1, 2, 3, 4 });

    var written: usize = undefined;

    // Write all 4 samples of the pattern
    written = try segment_writer.write(&segment, 0);
    try t.expectEqual(written, 4);

    // Write last 2 samples of the pattern
    written = try segment_writer.write(&segment, 2);
    try t.expectEqual(written, 2);

    // Write last 3 samples of the pattern
    written = try segment_writer.write(&segment, 1);
    try t.expectEqual(written, 3);

    // Ensure we're at correct position
    try t.expectEqual(segment_writer.write_index, 9);

    // Try to write the last 2 samples of the pattern,
    // but only 1 should be written
    written = try segment_writer.write(&segment, 2);
    try t.expectEqual(written, 1);

    // 0 Samples should be written when the buffer is full
    try t.expectEqual(segment_writer.write(&segment, 3), 0);

    const expected: []const f32 = &.{ 1, 2, 3, 4, 3, 4, 2, 3, 4, 3 };

    // Check that the samples are correct
    try t.expectEqualSlices(f32, expected, segment_writer.internal_segment.channel_pcm_buf[0]);

    // Check that the reset works
    segment_writer.reset(5);
    try t.expectEqual(segment_writer.write_index, 0);
    try t.expectEqual(segment_writer.internal_segment.index, 5);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");
const SplitSlice = @import("../structures/SplitSlice.zig").SplitSlice;

const Self = @This();

allocator: Allocator,
segment: Segment,
write_index: usize = 0,

pub fn init(allocator: Allocator, n_channels: usize, length: usize) !Self {
    var segment_ = try Segment.initWithCapacity(allocator, n_channels, length);
    errdefer segment_.deinit();

    var self = Self{
        .allocator = allocator,
        .segment = segment_,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    self.segment.deinit();
}

/// Writes the given segment to the buffer, returning the number of samples written.
/// When the return value is less than the length of the source buffer, it means that
/// the buffer is full and the buffer segment should be used in some way before
/// calling .reset(), followed by a second .write() with the offset returned from this call.
pub fn write(self: *Self, other: Segment, offset: usize) !usize {
    const segment = self.segment;

    // Determine the capacity of the internal buffer
    const capacity = segment.length;
    const remaining_capacity = capacity - self.write_index;

    if (remaining_capacity == 0) {
        return 0;
    }

    // number of source samples we have left to write
    const other_rem = other.length - offset;
    // number of source samples we can write before we fill the buffer
    const to_write = @min(remaining_capacity, other_rem);

    // Ensure the number of channels match
    if (segment.channel_pcm_buf.len != other.channel_pcm_buf.len) {
        return error.ChannelCountMismatch;
    }

    const n_channels = segment.channel_pcm_buf.len;

    for (0..n_channels) |chan_idx| {
        // SplitSlices of each channel
        var dst_chan = segment.channel_pcm_buf[chan_idx];
        var src_chan = other.channel_pcm_buf[chan_idx];

        // Source Segment could contain SplitSlices where both `.first` and `.second` half are populated
        // Determine the number of samples to copy from the `.first` half
        const n_from_first = if (src_chan.first.len > offset) @min(to_write, src_chan.first.len - offset) else 0;
        if (n_from_first > 0) {
            const dst_from = self.write_index;
            const src_from = offset;

            var dst_buf = dst_chan.first[dst_from .. dst_from + n_from_first];
            var src_buf = src_chan.first[src_from .. src_from + n_from_first];

            @memcpy(dst_buf, src_buf);
        }

        // Determine the number of samples to copy from the `.second` half
        if (n_from_first < to_write) {
            const rem = to_write - n_from_first;

            const dst_from = self.write_index + n_from_first;
            const src_from = if (offset >= src_chan.first.len) offset - src_chan.first.len else 0;

            var dst_buf = dst_chan.first[dst_from .. dst_from + rem];
            var src_buf = src_chan.second[src_from .. src_from + rem];

            @memcpy(dst_buf, src_buf);
        }
    }

    self.write_index += to_write;
    return to_write;
}

pub fn reset(self: *Self, new_segment_index: u64) void {
    self.write_index = 0;
    self.segment.index = new_segment_index;
}

//
// Tests
//

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const test_allocator = std.testing.allocator;

test "SegmentWriter" {
    var segment_writer = try init(test_allocator, 1, 10);
    defer segment_writer.deinit();

    const sample_pattern: []const f32 = &.{ 1, 2, 3, 4 };
    var segment_channels: []const SplitSlice(f32) = &.{
        SplitSlice(f32){
            .first = sample_pattern[0..1],
            .second = sample_pattern[1..],
        },
    };
    const segment = Segment{
        .index = 0,
        .allocator = null,
        .length = 4,
        .channel_pcm_buf = @constCast(segment_channels),
    };
    var written: usize = undefined;


    // Write all 4 samples of the pattern
    written = try segment_writer.write(segment, 0);
    try expectEqual(written, 4);
    
    // Write last 2 samples of the pattern
    written = try segment_writer.write(segment, 2);
    try expectEqual(written, 2);

    // Write last 3 samples of the pattern
    written = try segment_writer.write(segment, 1);
    try expectEqual(written, 3);

    // Ensure we're at correct position
    try expectEqual(segment_writer.write_index, 9);

    // Try to write the last 2 samples of the pattern, 
    // but only 1 should be written
    written = try segment_writer.write(segment, 2);
    try expectEqual(written, 1);

    // 0 Samples should be written when the buffer is full
    try expectEqual(segment_writer.write(segment, 3), 0);

    const expected: []const f32 = &.{ 1, 2, 3, 4, 3, 4, 2, 3, 4, 3 };

    // Check that the samples are correct
    try std.testing.expectEqualSlices(f32, expected, segment_writer.segment.channel_pcm_buf[0].first);

    // Check that the reset works
    segment_writer.reset(5);
    try expectEqual(segment_writer.write_index, 0);
    try expectEqual(segment_writer.segment.index, 5);
}

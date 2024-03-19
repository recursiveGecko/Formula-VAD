const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub fn MultiRingBuffer(comptime TData: type, comptime TCounter: type) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        capacity: TCounter,
        n_channels: usize,
        raw_buffer: []TData,
        channel_buffers: [][]TData,
        total_write_count: TCounter = 0,
        temp_split_slice: SplitSlice,

        pub const SplitSlice = struct {
            /// sample index of the first sample in `first` slice
            first_index: TCounter = 0,
            first: []const []const TData,
            /// sample index of the first sample in `second` slice
            second_index: TCounter = 0,
            second: []const []const TData,

            pub fn firstLength(self: *const @This()) TCounter {
                return self.first[0].len;
            }

            pub fn secondLength(self: *const @This()) TCounter {
                return self.second[0].len;
            }
        };

        pub fn init(allocator: Allocator, n_channels: usize, capacity: usize) !Self {
            var raw_buffer = try allocator.alloc(TData, n_channels * capacity);
            errdefer allocator.free(raw_buffer);

            const channel_buffers = try allocator.alloc([]TData, n_channels);
            errdefer allocator.free(channel_buffers);

            const temp_split_slice = SplitSlice{
                .first = try allocator.alloc([]TData, n_channels),
                .second = try allocator.alloc([]TData, n_channels),
            };

            for (0..n_channels) |i| {
                const from = i * capacity;
                const to = from + capacity;
                channel_buffers[i] = raw_buffer[from..to];
            }

            const self = Self{
                .allocator = allocator,
                .n_channels = n_channels,
                .capacity = capacity,
                .raw_buffer = raw_buffer,
                .channel_buffers = channel_buffers,
                .temp_split_slice = temp_split_slice,
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.raw_buffer);
            self.allocator.free(self.channel_buffers);
            self.allocator.free(self.temp_split_slice.first);
            self.allocator.free(self.temp_split_slice.second);
        }

        pub fn writeIndex(self: *const Self) usize {
            return self.total_write_count % self.capacity;
        }

        /// Writes multiple channels of data to the ring buffer.
        ///
        /// Note that this function does nothing to stop the caller from supplying enough data to
        /// overwrite every element multiple times (i.e. overflow)
        /// It is up to the caller to ensure that an appropriate `max_write_count` is supplied
        /// that allows the caller to process the data after every write operation.
        pub fn write(
            self: *Self,
            source_channels: []const []const TData,
            src_read_offset: usize,
            max_write_count: usize,
        ) usize {
            // Given the source read offset and maximum number of elements to write,
            // calculate the maximum element index that we can read from the source buffer
            const max_src_read_idx = src_read_offset + max_write_count;

            // Operations which would overflow the ring buffer are split into multiple steps.
            var n_written: usize = 0;
            while (true) {
                // Source offset for this step/iteration
                const step_src_offset = src_read_offset + n_written;
                // This can be more that the actual number of elements
                // that remain in the source buffer, but that's fine.
                // This simply determines the upper bound.
                const remaining_readable = max_src_read_idx - step_src_offset;
                const step_max_write_count = @min(
                    self.capacity,
                    remaining_readable,
                );

                const n_step = self.writeAssumeCapacity(source_channels, step_src_offset, step_max_write_count);
                n_written += n_step;

                if (n_step < self.capacity) break;
            }

            return n_written;
        }

        pub fn writeAssumeCapacity(
            self: *Self,
            source_channels: []const []const TData,
            src_read_offset: usize,
            max_write_count: usize,
        ) usize {
            // Assert that we have the same number of channels as configured
            assert(source_channels.len == self.n_channels);
            const n_total_src_points = source_channels[0].len;

            // Assert that all source channels have the same number of data points
            for (0..self.n_channels) |channel_idx| {
                assert(source_channels[channel_idx].len == n_total_src_points);
            }

            const dst_write_idx = self.writeIndex();
            // Number of elements remaining until we reach the end of the ring buffer
            // and need to start writing from the start again
            const dst_distance_to_end = self.capacity - dst_write_idx;
            // Number of elements remaining in the input/source buffer
            const src_remaining = val: {
                // Prevent underflow
                if (n_total_src_points < src_read_offset) break :val 0;
                break :val n_total_src_points - src_read_offset;
            };

            // Number of elements to write (per channel)
            const n_write_total_count = @min(src_remaining, max_write_count);
            // Number of elements to write until the end of the ring buffer
            const n_write_to_end_count = @min(dst_distance_to_end, n_write_total_count);
            // Number of elements to write from the start of the ring buffer, usually 0
            const n_write_from_start_count = n_write_total_count - n_write_to_end_count;

            // Assert that we can complete the write operation in a single step
            assert(n_write_total_count <= self.capacity);

            if (n_write_total_count == 0) {
                return 0;
            }

            for (0..self.n_channels) |channel_idx| {
                var src_channel = source_channels[channel_idx];
                var dst_channel = self.channel_buffers[channel_idx];

                // Step 1. Write to the end of the ring buffer
                var src_from: usize = src_read_offset;
                var src_to: usize = src_from + n_write_to_end_count;
                var dst_from: usize = dst_write_idx;
                var dst_to: usize = dst_from + n_write_to_end_count;

                var src_read_slice = src_channel[src_from..src_to];
                var dst_write_slice = dst_channel[dst_from..dst_to];
                @memcpy(dst_write_slice, src_read_slice);

                // Step 2. Write from the start of the ring buffer
                if (n_write_from_start_count > 0) {
                    src_from = src_read_offset + n_write_to_end_count;
                    src_to = src_from + n_write_from_start_count;
                    dst_from = 0;
                    dst_to = n_write_from_start_count;

                    src_read_slice = src_channel[src_from..src_to];
                    dst_write_slice = dst_channel[dst_from..dst_to];
                    @memcpy(dst_write_slice, src_read_slice);
                }
            }

            self.total_write_count += n_write_total_count;
            return n_write_total_count;
        }

        /// Returns a split slice of multi-channel ring buffer
        pub fn sliceBuffer(
            self: *Self,
            abs_from: TCounter,
            abs_to: TCounter,
        ) !SplitSlice {
            // Valid slicing range
            const max_abs_idx = self.total_write_count;
            const min_abs_idx = max_abs_idx - @min(self.capacity, max_abs_idx);

            if (abs_to <= abs_from) {
                return error.InvalidRange;
            }

            if (abs_to - abs_from > self.capacity) {
                return error.RangeTooLong;
            }

            if (abs_from < min_abs_idx or abs_to > max_abs_idx) {
                return error.IndexOutOfBounds;
            }

            const total_length = abs_to - abs_from;

            // Convert absolute indices to relative indices
            const rel_start = abs_from % self.capacity;

            // number of samples to copy from `rel_start` position to the end of the buffer
            const n_to_end = @min(total_length, self.capacity - rel_start);

            // std.debug.print("abs: [{d:10}, {d:10} )   rel: [{d:10} .. +{d:8} )\n", .{ abs_from, abs_to, rel_start, n_to_end });

            var split_slice = self.temp_split_slice;
            const sliceable_first = @constCast(split_slice.first);
            const sliceable_second = @constCast(split_slice.second);

            split_slice.first_index = abs_from;
            split_slice.second_index = abs_from + n_to_end;

            for (0..self.n_channels) |channel_idx| {
                const src_channel = self.channel_buffers[channel_idx];

                sliceable_first[channel_idx] = src_channel[rel_start .. rel_start + n_to_end];
                sliceable_second[channel_idx] = src_channel[0 .. total_length - n_to_end];
            }

            return split_slice;
        }
    };
}

const t = std.testing;
const test_allocator = std.testing.allocator;

test "write() ring buffer handling" {
    var mr_buffer = try MultiRingBuffer(i32, u64).init(test_allocator, 1, 5);
    defer mr_buffer.deinit();

    const pcm = mr_buffer.channel_buffers[0];
    @memset(pcm, 0);

    _ = mr_buffer.write(&.{&.{ 8, 1, 2, 9, 9, 9 }}, 0, 2);
    // write index:       v
    // expected:   [8, 1, _, _, _]
    try t.expectEqualSlices(i32, &.{ 8, 1, 0, 0, 0 }, pcm);

    _ = mr_buffer.write(&.{&.{ 8, 1, 2, 9, 9, 9 }}, 1, 1);
    // write index:          v
    // expected:   [8, 1, 1, _, _]
    try t.expectEqualSlices(i32, &.{ 8, 1, 1, 0, 0 }, pcm);

    _ = mr_buffer.write(&.{&.{ 4, 5, 6, 7, 8, 9 }}, 0, 9999);
    // write index:             v
    // expected:   [6, 7, 8, 9, 5]
    try t.expectEqualSlices(i32, &.{ 6, 7, 8, 9, 5 }, pcm);

    _ = mr_buffer.write(&.{&.{ 2, 3, 4 }}, 0, 9999);
    // write index:       v
    // expected:   [3, 4, 8, 9, 2]
    try t.expectEqualSlices(i32, &.{ 3, 4, 8, 9, 2 }, pcm);

    _ = mr_buffer.write(&.{&.{ 0, 0, 0, 0, 0, 50, 60, 70, 80, 90 }}, 0, 9999);
    // write index:         v
    // expected:   [80, 90, 50, 60, 70]
    try t.expectEqualSlices(i32, &.{ 80, 90, 50, 60, 70 }, pcm);

    _ = mr_buffer.write(&.{&.{ -1, 0, 2, 0 }}, 0, 9999);
    // write index:    v
    // expected:   [0, 90, -1, 0, 2]
    try t.expectEqualSlices(i32, &.{ 0, 90, -1, 0, 2 }, pcm);

    _ = mr_buffer.write(&.{&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, -1, -2 }}, 4, 3);
    // write index:             v
    // expected:   [0, 5, 6, 7, 2]
    try t.expectEqualSlices(i32, &.{ 0, 5, 6, 7, 2 }, pcm);

    _ = mr_buffer.write(&.{&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, -1, -2 }}, 8, 3);
    // write index:         v
    // expected:   [-1, -2, 6, 7, 9]
    try t.expectEqualSlices(i32, &.{ -1, -2, 6, 7, 9 }, pcm);
}

test "sliceBuffer()" {
    var mr_buffer = try MultiRingBuffer(i32, u64).init(test_allocator, 1, 5);
    defer mr_buffer.deinit();

    const pcm = mr_buffer.channel_buffers[0];
    @memset(pcm, 0);

    // write 8 samples to the buffer
    _ = mr_buffer.write(&.{&.{ 7, 1, 2, 9, 4, 3, 8, 5 }}, 0, 1000);
    // write index:          v
    // expected:   [3, 8, 5, 9, 4]
    try t.expectEqualSlices(i32, &.{ 3, 8, 5, 9, 4 }, pcm);

    const split_slice = try mr_buffer.sliceBuffer(3, 8);

    try t.expectEqualSlices(i32, &.{ 9, 4 }, split_slice.first[0]);
    try t.expectEqual(3, split_slice.first_index);
    try t.expectEqual(2, split_slice.firstLength());

    try t.expectEqualSlices(i32, &.{ 3, 8, 5 }, split_slice.second[0]);
    try t.expectEqual(5, split_slice.second_index);
    try t.expectEqual(3, split_slice.secondLength());
}

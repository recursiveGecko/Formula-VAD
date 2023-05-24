const std = @import("std");
const Allocator = std.mem.Allocator;

/// `SplitSlice` is a generic data structure comprised of two slices.
/// It's useful when data is read from a circular buffer which may wrap
/// around the end of the buffer. In that scenario it can represent a section
/// of data that isn't contiguous in memory without having to create a copy.
pub fn SplitSlice(comptime T: type) type {
    return struct {
        const Self = @This();

        id: u64 = 0,
        first: []T,
        second: []T = &.{},
        allocator: ?Allocator = null,
        /// Which slices to free when deinit is called.
        owned_slices: enum { none, first, second, both } = .none,

        pub fn initWithCapacity(allocator: Allocator, length: usize) !Self {
            var data = try allocator.alloc(T, length);
            errdefer allocator.free(data);

            const self = Self{
                .id = undefined,
                .first = data,
                .allocator = allocator,
                .owned_slices = .first,
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.allocator) |allocator| {
                switch (self.owned_slices) {
                    .none => {},
                    .first => allocator.free(self.first),
                    .second => allocator.free(self.second),
                    .both => {
                        allocator.free(self.first);
                        allocator.free(self.second);
                    },
                }

                self.owned_slices = .none;
            }
        }

        pub fn len(self: Self) usize {
            return self.first.len + self.second.len;
        }

        /// Create a deep copy of the SplitSlice.
        pub fn copy(self: Self, allocator: Allocator) !Self {
            var new_self = try self.copyCapacity(allocator);
            errdefer new_self.deinit();

            std.mem.copyForwards(T, @constCast(new_self.first[0..]), self.first);
            std.mem.copyForwards(T, @constCast(new_self.first[self.first.len..]), self.second);

            return new_self;
        }

        /// Copies the capacity of the original SplitSlice, but not the contents.
        /// SplitSlice shape is not copied exactly, instead `.first` slice has the
        /// capacity of `.first.len` + `.second.len`
        pub fn copyCapacity(self: Self, allocator: Allocator) !Self {
            var data = try allocator.alloc(T, self.first.len + self.second.len);
            errdefer allocator.free(data);

            const new_self = Self{
                .id = self.id,
                .first = data,
                .allocator = allocator,
                .owned_slices = .first,
            };

            return new_self;
        }

        pub fn resize(self: *Self, new_size: usize, init_val: T) !void {
            // Only SplitSlices which own the first slice and
            // don't have a second slice can be resized.
            if (self.owned_slices != .first) return error.Unsupported;

            const current_size = self.first.len;

            const resized = self.allocator.?.resize(self.first, new_size);
            if (resized) {
                self.first = self.first[0..new_size];
                return;
            }

            var new_first = try self.allocator.?.alloc(T, new_size);
            errdefer self.allocator.?.free(new_first);

            const n_to_copy = @min(current_size, new_size);
            var src = self.first[0..n_to_copy];
            var dst = new_first[0..n_to_copy];
            @memcpy(dst, src);

            for (n_to_copy..new_size) |i| {
                new_first[i] = init_val;
            }

            self.allocator.?.free(self.first);
            self.first = new_first;
        }
    };
}

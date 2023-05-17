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
        first: []const T,
        second: []const T = &.{},
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
    };
}

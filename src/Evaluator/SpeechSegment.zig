const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Self = @This();

id: i64 = -1,
from_sec: f32,
to_sec: f32,
side: enum{ vad, ref },

opposite_segments: ?[]*Self = null,
next: ?*Self = null,
prev: ?*Self = null,
late_start_sec: f32 = 0,
debug_info: ?[]const u8 = null,

pub fn duration(self: Self) f32 {
    return self.to_sec - self.from_sec;
}

pub fn overlapWith(self: Self, other: Self) f32 {
    const max_from = @max(self.from_sec, other.from_sec);
    const min_to = @min(self.to_sec, other.to_sec);

    return min_to - max_from;
}

pub fn hasMatch(self: Self) bool {
    return self.opposite_segments.?.len > 0;
}

pub fn toComment(self: Self, allocator: Allocator) ![]const u8 {
    if (self.hasMatch()) {
        return try std.fmt.allocPrint(allocator, "{s}", .{self.debug_info orelse ""});
    } else {
        return try std.fmt.allocPrint(allocator, "UNMATCHED {s}", .{self.debug_info orelse ""});
    }
}

pub fn findOverlapping(allocator: Allocator, target: *Self, others: []Self) ![]*Self {
    var overlapping = ArrayList(*Self).init(allocator);
    errdefer overlapping.deinit();

    for (others) |*other| {
        if (target.overlapWith(other.*) > 0.0) {
            try overlapping.append(other);
        }
    }

    return overlapping.toOwnedSlice();
}

pub fn sortByStart(_ctx: void, lhs: Self, rhs: Self) bool {
    _ = _ctx;
    return lhs.from_sec <= rhs.from_sec;
}
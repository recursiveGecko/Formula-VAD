const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Self = @This();

from_sec: f32,
to_sec: f32,

opposite_match_count: usize = 0,
// TODO: Not implemented
overlap: ?f32 = null,
// TODO: Not implemented
start_delta: ?f32 = null,
// TODO: Not implemented
end_delta: ?f32 = null,
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
    return self.opposite_match_count > 0;
}

pub fn toComment(self: Self, allocator: Allocator) ![]const u8 {
    var prefix: []const u8 = undefined;
    if (self.hasMatch()) {
        prefix = "";
    } else {
        prefix = "!!";
    }

    return try std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, self.debug_info orelse "" });
}

pub fn findOverlapping(allocator: Allocator, target: Self, others: []Self) ![]*Self {
    var overlapping = ArrayList(*Self).init(allocator);
    errdefer overlapping.deinit();

    for (others) |*other| {
        if (target.overlapWith(other.*) > 0.0) {
            try overlapping.append(other);
        }
    }

    return overlapping.toOwnedSlice();
}
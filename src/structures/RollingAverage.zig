const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();

allocator: Allocator,
data: []f64,
write_idx: usize = 0,
written_count: usize = 0,

pub fn init(allocator: Allocator, count: usize) !Self {
    var data = try allocator.alloc(f64, count);

    return Self {
        .allocator = allocator,
        .data = data,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.data);
}

pub fn push(self: *Self, sample: f32) f64 {
    self.data[self.write_idx] = sample;
    self.write_idx = (self.write_idx + 1) % self.data.len;

    if(self.written_count < self.data.len) {
        self.written_count += 1;
    }

    return self.avg();
}

pub fn avg(self: *Self) f64 {
    var avg_: f64 = 0.0;
    var scalar: f64 = 1.0 / @intToFloat(f64, self.written_count);
    
    for (0..self.written_count) |i| {
        avg_ += self.data[i] * scalar;
    }

    return avg_;
}
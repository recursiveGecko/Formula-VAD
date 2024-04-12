const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();

allocator: Allocator,
data: []f32,
current_avg: ?f32 = null,
write_idx: usize = 0,
written_count: usize = 0,

pub fn init(allocator: Allocator, count: usize, initial_val: ?f32) !Self {
    const data = try allocator.alloc(f32, count);

    var self = Self{
        .allocator = allocator,
        .data = data,
    };

    if (initial_val) |val| {
        for (0..count) |i| {
            self.data[i] = val;
        }
        self.written_count = count;
        _ = self.avg();
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.data);
}

pub fn push(self: *Self, sample: f32) f32 {
    const replaced_sample = self.data[self.write_idx];
    self.data[self.write_idx] = sample;
    self.write_idx = (self.write_idx + 1) % self.data.len;

    if (self.written_count < self.data.len) {
        self.written_count += 1;
    }

    if (self.write_idx == 0 or self.current_avg == null) {
        return self.avg();
    } else {
        const scalar = self.sampleWeight();
        const current_avg_f64: f64 = @floatCast(self.current_avg.?);
        const new_avg = current_avg_f64 - (replaced_sample * scalar) + (sample * scalar);

        self.current_avg = @floatCast(new_avg);
        return self.current_avg.?;
    }
}

pub fn avg(self: *Self) f32 {
    var avg_: f64 = 0.0;
    const scalar = self.sampleWeight();

    for (0..self.written_count) |i| {
        avg_ += self.data[i] * scalar;
    }

    self.current_avg = @floatCast(avg_);

    return @floatCast(avg_);
}

fn sampleWeight(self: *const Self) f64 {
    return 1.0 / @as(f64, @floatFromInt(self.written_count));
}

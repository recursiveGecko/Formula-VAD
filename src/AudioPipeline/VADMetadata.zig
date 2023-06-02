const std = @import("std");

const Self = @This();

pub const Result = struct {
    volume_ratio: ?f32 = null,
    volume_min: ?f32 = null,
    volume_max: ?f32 = null,
    rnn_vad: ?f32 = null,
};

volume_ratio_sum: ?f32 = null,
volume_ratio_weight: ?f32 = null,
volume_min: ?f32 = null,
volume_max: ?f32 = null,
rnn_vad_sum: ?f32 = null,
rnn_vad_weight: ?f32 = null,

pub fn toResult(self: *Self) Result {
    var data = Result{};

    data.volume_min = self.volume_min;
    data.volume_max = self.volume_max;

    if (self.volume_ratio_sum != null) {
        data.volume_ratio = self.volume_ratio_sum.? / self.volume_ratio_weight.?;
    }

    if (self.rnn_vad_sum != null) {
        data.rnn_vad = self.rnn_vad_sum.? / self.rnn_vad_weight.?;
    }

    return data;
}

pub fn push(self: *Self, values: anytype, weight_any: anytype) void {
    const weight = if (@typeInfo(@TypeOf(weight_any)) == .Int)
        @intToFloat(f32, weight_any)
    else
        weight_any;

    const new_volume_ratio = getValueOrNull(f32, values, "volume_ratio");
    const new_rnn_vad = getValueOrNull(f32, values, "rnn_vad");
    const new_volume_min = getValueOrNull(f32, values, "volume_min");
    const new_volume_max = getValueOrNull(f32, values, "volume_max");

    if (new_volume_ratio) |new_val| {
        if (self.volume_ratio_sum == null) {
            self.volume_ratio_sum = 0.0;
            self.volume_ratio_weight = 0.0;
        }

        self.volume_ratio_sum.? += new_val * weight;
        self.volume_ratio_weight.? += weight;
    }

    if (new_rnn_vad) |new_val| {
        if (self.rnn_vad_sum == null) {
            self.rnn_vad_sum = 0.0;
            self.rnn_vad_weight = 0.0;
        }

        self.rnn_vad_sum.? += new_val * weight;
        self.rnn_vad_weight.? += weight;
    }

    if (new_volume_min) |new_val| {
        if (self.volume_min == null or new_val < self.volume_min.?) {
            self.volume_min = new_val;
        }
    }

    if (new_volume_max) |new_val| {
        if (self.volume_max == null or new_val > self.volume_max.?) {
            self.volume_max = new_val;
        }
    }
}

fn getValueOrNull(comptime T: type, obj: anytype, comptime field: []const u8) ?T {
    const T_obj = @TypeOf(obj);
    if (!@hasField(T_obj, field)) return null;
    return @field(obj, field);
}

const t = std.testing;

test "volume_min" {
    var metadata = Self{};

    metadata.push(.{ .volume_min = 100 }, 1);
    metadata.push(.{ .volume_min = 80 }, 1);
    metadata.push(.{ .volume_min = 90 }, 1);

    const res = metadata.toResult();
    try t.expectApproxEqAbs(res.volume_min.?, 80.0, 0.001);
}

test "volume_max" {
    var metadata = Self{};

    metadata.push(.{ .volume_max = 80 }, 1);
    metadata.push(.{ .volume_max = 100 }, 1);
    metadata.push(.{ .volume_max = 90 }, 1);

    const res = metadata.toResult();
    try t.expectApproxEqAbs(res.volume_max.?, 100.0, 0.001);
}

test "volume_ratio" {
    var metadata = Self{};

    metadata.push(.{ .volume_ratio = 0.9 }, 1);
    metadata.push(.{ .volume_ratio = 0.8 }, 1);

    const res = metadata.toResult();
    try t.expectApproxEqAbs(res.volume_ratio.?, 0.85, 0.001);
}

test "volume_ratio (weighted)" {
    var metadata = Self{};

    metadata.push(.{ .volume_ratio = 1.0 }, 1);
    metadata.push(.{ .volume_ratio = 0.0 }, 9);

    const res = metadata.toResult();
    try t.expectApproxEqAbs(res.volume_ratio.?, 0.1, 0.001);
}

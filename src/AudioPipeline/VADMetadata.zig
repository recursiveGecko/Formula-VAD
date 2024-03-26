const std = @import("std");

const Self = @This();

pub const Result = struct {
    volume_ratio: ?f32 = null,
    volume_rms: ?f32 = null,
    silero_vad: ?f32 = null,
};

volume_ratio_sum: ?f32 = null,
volume_ratio_weight: ?f32 = null,
volume_rms_sum: ?f32 = null,
volume_rms_weight: ?f32 = null,
silero_vad_sum: ?f32 = null,
silero_vad_weight: ?f32 = null,

pub fn toResult(self: *Self) Result {
    var data = Result{};

    if (self.volume_ratio_sum != null) {
        data.volume_ratio = self.volume_ratio_sum.? / self.volume_ratio_weight.?;
    }

    if (self.silero_vad_sum != null) {
        data.silero_vad = self.silero_vad_sum.? / self.silero_vad_weight.?;
    }

    if (self.volume_rms_sum != null) {
        data.volume_rms = self.volume_rms_sum.? / self.volume_rms_weight.?;
    }

    return data;
}

pub fn push(self: *Self, values: anytype, weight_any: anytype) void {
    const weight = if (@typeInfo(@TypeOf(weight_any)) == .Int)
        @as(f32, @floatFromInt(weight_any))
    else
        weight_any;

    const new_volume_ratio = getValueOrNull(f32, values, "volume_ratio");
    const new_silero_vad = getValueOrNull(f32, values, "silero_vad");
    const new_volume_rms = getValueOrNull(f32, values, "volume_rms");

    if (new_volume_ratio) |new_val| {
        if (self.volume_ratio_sum == null) {
            self.volume_ratio_sum = 0.0;
            self.volume_ratio_weight = 0.0;
        }

        self.volume_ratio_sum.? += new_val * weight;
        self.volume_ratio_weight.? += weight;
    }

    if (new_volume_rms) |new_val| {
        if (self.volume_rms_sum == null) {
            self.volume_rms_sum = 0.0;
            self.volume_rms_weight = 0.0;
        }

        self.volume_rms_sum.? += new_val * weight;
        self.volume_rms_weight.? += weight;
    }

    if (new_silero_vad) |new_val| {
        if (self.silero_vad_sum == null) {
            self.silero_vad_sum = 0.0;
            self.silero_vad_weight = 0.0;
        }

        self.silero_vad_sum.? += new_val * weight;
        self.silero_vad_weight.? += weight;
    }
}

fn getValueOrNull(comptime T: type, obj: anytype, comptime field: []const u8) ?T {
    const T_info = @typeInfo(T);

    const TNonOptional = if (T_info == .Optional) T_info.Optional.child else T;

    const TObj = @TypeOf(obj);
    if (!@hasField(TObj, field)) return null;

    const maybe_val: ?TNonOptional = @field(obj, field);
    if (maybe_val == null) return null;

    const val: TNonOptional = maybe_val.?;
    if (@typeInfo(TNonOptional) == .Float and !std.math.isFinite(val)) {
        return null;
    }

    return val;
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

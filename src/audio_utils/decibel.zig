const std = @import("std");

/// Convert [0, 1] normalized values to dbFS
pub fn normToDBFS(values: []f32) void {
    const eps = std.math.f32_epsilon;
    for (values) |*value| {
        std.debug.assert(value.* < (1 + eps));
        value.* = 20.0 * std.math.log10(value.*);
    }
}

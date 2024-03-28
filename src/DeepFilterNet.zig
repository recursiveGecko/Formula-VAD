//! Wrapper for DeepFilterNet denoiser
//!
const Allocator = std.mem.Allocator;
const std = @import("std");
const df = @cImport({
    @cInclude("deep_filter/deep_filter.h");
});
const log = std.log.scoped(.deep_filter_net);

const Self = @This();

allocator: std.mem.Allocator,
in_sample_rate: usize,
frame_length: usize,
df_state: *df.DFState,

pub fn init(
    allocator: std.mem.Allocator,
    sample_rate: usize,
    attenuation: f32,
    model_path: [:0]const u8,
) !Self {
    if (sample_rate != 48000) {
        // DeepFilterNet doesn't support any other sampling rates
        return error.UnsupportedSampleRate;
    }

    const df_state = df.df_create(model_path, attenuation, "error");

    if (df_state == null) {
        return error.InitializationFailed;
    }
    errdefer df.df_free(df_state);

    const self = Self{
        .allocator = allocator,
        .in_sample_rate = sample_rate,
        .df_state = df_state.?,
        .frame_length = df.df_get_frame_length(df_state),
    };

    // self.consumeLogs();

    return self;
}

pub fn deinit(self: *Self) void {
    df.df_free(self.df_state);
}

pub fn getChunkSize(self: *const Self) usize {
    return self.frame_length;
}

pub fn denoise(self: *Self, in_samples: []const f32, out_samples: []f32) !void {
    if (in_samples.len != self.frame_length) {
        return error.InvalidInputLength;
    }

    if (out_samples.len != self.frame_length) {
        return error.InvalidInputLength;
    }

    const snr = df.df_process_frame(self.df_state, @constCast(in_samples.ptr), out_samples.ptr);
    _ = snr;

    // self.consumeLogs();
}

// fn consumeLogs(self: *const Self) void {
//     while (df.df_next_log_msg(self.df_state)) |msg| {
//         defer df.df_free_log_msg(msg);

//         log.info("{s}", .{msg});
//     }
// }

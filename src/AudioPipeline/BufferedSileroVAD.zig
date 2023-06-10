const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const VADMetadata = @import("./VADMetadata.zig");
const BufferedStep = @import("./BufferedStep.zig");
const SileroVAD = @import("../SileroVAD.zig");

const Self = @This();
pub const Result = struct {
    n_remaining_input: usize,
    index: ?u64,
    input_length: ?usize,
    vad: ?f32,
    vad_min: ?f32,
    vad_max: ?f32,
    metadata: ?VADMetadata.Result,
};

allocator: Allocator,
n_channels: usize,
sample_rate: usize,
silero_vads: []SileroVAD,
buffer: SegmentWriter,
vad_metadata: VADMetadata = .{},

pub fn init(
    allocator: Allocator,
    n_channels: usize,
    sample_rate: usize,
) !Self {
    var silero_vads = try allocator.alloc(SileroVAD, n_channels);
    for (0..n_channels) |i| {
        silero_vads[i] = try SileroVAD.init(allocator, sample_rate);
    }
    errdefer {
        for (0..n_channels) |i| silero_vads[i].deinit();
        allocator.free(silero_vads);
    }

    var buffer = try SegmentWriter.init(allocator, n_channels, getChunkSizeForSR(sample_rate));
    errdefer buffer.deinit();

    return Self{
        .allocator = allocator,
        .n_channels = n_channels,
        .sample_rate = sample_rate,
        .silero_vads = silero_vads,
        .buffer = buffer,
    };
}

pub fn deinit(self: *Self) void {
    for (self.silero_vads) |*s| s.deinit();
    self.allocator.free(self.silero_vads);
    self.buffer.deinit();
}

pub fn getChunkSize(self: *Self) usize {
    return getChunkSizeForSR(self.sample_rate);
}

pub fn getChunkSizeForSR(sample_rate: usize) usize {
    return SileroVAD.getChunkSizeForSR(sample_rate);
}

pub fn write(
    self: *Self,
    input: *const BufferedStep.Result,
    input_offset: usize,
) !Result {
    const n_written = try self.buffer.write(input.segment, input_offset, null);
    const n_remaining_input = input.segment.length - input_offset - n_written;

    self.vad_metadata.push(
        input.metadata,
        n_written,
    );

    if (!self.buffer.isFull()) {
        return Result{
            .n_remaining_input = n_remaining_input,
            .index = null,
            .input_length = null,
            .vad = null,
            .vad_min = null,
            .vad_max = null,
            .metadata = null,
        };
    }

    defer {
        self.buffer.reset(input.segment.index + input_offset + n_written);
        self.vad_metadata = .{};
    }

    var vad_min: f32 = 1;
    var vad_max: f32 = 0;
    var vad_sum: f32 = 0;

    for (0..self.n_channels) |i| {
        var vad = try self.silero_vads[0].runVAD(
            self.buffer.segment.channel_pcm_buf[i],
        );

        if(vad < vad_min) vad_min = vad;
        if(vad > vad_max) vad_max = vad;
        vad_sum += vad;
    }

    var vad_avg = vad_sum / @intToFloat(f32, self.n_channels);

    const result = Result{
        .index = self.buffer.segment.index,
        .input_length = self.buffer.segment.length,
        .vad = vad_avg,
        .vad_min = vad_min,
        .vad_max = vad_max,
        .metadata = self.vad_metadata.toResult(),
        .n_remaining_input = n_remaining_input,
    };

    return result;
}

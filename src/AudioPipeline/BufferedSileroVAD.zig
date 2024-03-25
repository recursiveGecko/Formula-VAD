const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const VADMetadata = @import("./VADMetadata.zig");
const BufferedStep = @import("./BufferedStep.zig");
const SileroVAD = @import("../SileroVAD.zig");

const Self = @This();

allocator: Allocator,
vad: SileroVAD,
step: *BufferedStep,
out_result: BufferedStep.Result,

pub fn init(
    allocator: Allocator,
    name: []const u8,
    in_sample_rate: usize,
    expect_output: bool,
) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    var vad = try SileroVAD.init(allocator, in_sample_rate);
    errdefer vad.deinit();

    self.* = .{
        .allocator = allocator,
        .vad = vad,
        .step = undefined,
        .out_result = undefined,
    };

    self.step = try BufferedStep.init(
        allocator,
        name,
        .{
            .buffer_size = vad.getChunkSize(),
            .in_channels = 1,
            .in_sample_rate = in_sample_rate,
            .out_channels = 1,
            .out_sample_rate = in_sample_rate,
            .expect_output = expect_output,
        },
        BufferedStep.Processor.forContext(self),
    );
    errdefer self.step.deinit();

    return self;
}

pub fn deinit(self: *Self) void {
    self.vad.deinit();
    self.step.deinit();
    self.allocator.destroy(self);
}

pub fn process(
    self: *Self,
    input: *const BufferedStep.Result,
) *const BufferedStep.Result {
    const vad_value = self.vad.runVAD(input.segment.channel_pcm_buf[0]) catch |err| {
        std.debug.panic("SileroVAD.runVAD() failed with error: {any}", .{err});
    };

    var metadata = input.metadata;
    metadata.silero_vad = vad_value;

    self.out_result = input.*;
    self.out_result.metadata = metadata;
    return &self.out_result;
}

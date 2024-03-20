const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const VADMetadata = @import("./VADMetadata.zig");
const BufferedStep = @import("./BufferedStep.zig");
const NSNet2 = @import("../NSNet2.zig");

const Self = @This();

allocator: Allocator,
denoiser: NSNet2,
out_segment: Segment,
out_result: BufferedStep.Result,
audio_config: BufferedStep.AudioConfig,
step: *BufferedStep,

pub fn init(
    allocator: Allocator,
    name: []const u8,
    model_path: ?[:0]const u8,
    in_sample_rate: usize,
    expect_output: bool,
) !*Self {
    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    var out_segment = try Segment.initWithCapacity(
        allocator,
        1,
        NSNet2.getChunkSize(in_sample_rate),
    );
    errdefer out_segment.deinit();

    var denoiser = try NSNet2.init(allocator, in_sample_rate, model_path);
    errdefer denoiser.deinit();

    self.* = .{
        .allocator = allocator,
        .denoiser = denoiser,
        .out_segment = out_segment,
        .out_result = .{
            .metadata = .{},
            .segment = &self.out_segment,
        },
        .audio_config = .{
            .buffer_size = NSNet2.getChunkSize(in_sample_rate),
            .in_channels = 1,
            .in_sample_rate = in_sample_rate,
            .out_channels = 1,
            .out_sample_rate = in_sample_rate,
            .expect_output = expect_output,
        },
        .step = undefined,
    };

    self.step = try BufferedStep.init(
        allocator,
        name,
        self.audio_config,
        BufferedStep.Processor.forContext(self),
    );
    errdefer self.step.deinit();

    return self;
}

pub fn deinit(self: *Self) void {
    self.denoiser.deinit();
    self.out_segment.deinit();
    self.step.deinit();
    self.allocator.destroy(self);
}

pub fn process(
    self: *Self,
    input: *const BufferedStep.Result,
) *const BufferedStep.Result {
    const in_pcm = input.segment.channel_pcm_buf[0];
    const out_pcm = self.out_segment.writablePCM()[0];

    self.denoiser.denoise(in_pcm, out_pcm) catch |err| {
        std.debug.panic("BufferedDenoiser '{s}': denoising failed: {any}", .{ self.step.name, err });
    };

    self.out_segment.index = input.segment.index;
    self.out_result.metadata = input.metadata;
    return &self.out_result;
}

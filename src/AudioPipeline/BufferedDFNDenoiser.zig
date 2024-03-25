const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");
const VADMetadata = @import("./VADMetadata.zig");
const BufferedStep = @import("./BufferedStep.zig");
const DeepFilterNet = @import("../DeepFilterNet.zig");

const Self = @This();

const default_model_path = "data/DeepFilterNet3_onnx.tar.gz";

allocator: Allocator,
denoiser: DeepFilterNet,
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

    var denoiser = try DeepFilterNet.init(allocator, in_sample_rate, model_path orelse default_model_path);
    errdefer denoiser.deinit();

    var out_segment = try Segment.initWithCapacity(
        allocator,
        1,
        denoiser.getChunkSize(),
    );
    errdefer out_segment.deinit();

    self.* = .{
        .allocator = allocator,
        .denoiser = denoiser,
        .out_segment = out_segment,
        .out_result = .{
            .metadata = .{},
            .segment = &self.out_segment,
        },
        .audio_config = .{
            .buffer_size = denoiser.getChunkSize(),
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
        std.debug.panic("BufferedDFNDenoiser '{s}': denoising failed: {any}", .{ self.step.name, err });
    };

    self.out_segment.index = input.segment.index;
    self.out_result.metadata = input.metadata;
    return &self.out_result;
}

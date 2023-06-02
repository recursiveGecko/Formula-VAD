const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const VADMetadata = @import("./VADMetadata.zig");
const BufferedStep = @import("./BufferedStep.zig");
const Denoiser = @import("../Denoiser.zig");

const Self = @This();
pub const Result = struct {
    input_segment: *const Segment,
    denoised_segment: ?*const Segment,
    n_remaining_input: usize,
    metadata: ?VADMetadata.Result,
};

allocator: Allocator,
n_channels: usize,
denoisers: []Denoiser,
buffer: SegmentWriter,
vad_metadata: VADMetadata = .{},
temp_result_segment: Segment,

pub fn init(allocator: Allocator, n_channels: usize) !Self {
    const temp_result_segment = try Segment.initWithCapacity(
        allocator,
        n_channels,
        Denoiser.getFrameSize(),
    );

    var denoisers = try allocator.alloc(Denoiser, n_channels);
    for (0..n_channels) |i| {
        denoisers[i] = try Denoiser.init(allocator);
    }
    errdefer {
        for (0..n_channels) |i| denoisers[i].deinit();
        allocator.free(denoisers);
    }

    var buffer = try SegmentWriter.init(allocator, n_channels, Denoiser.getFrameSize());
    errdefer buffer.deinit();

    return Self{
        .allocator = allocator,
        .n_channels = n_channels,
        .denoisers = denoisers,
        .temp_result_segment = temp_result_segment,
        .buffer = buffer,
    };
}

pub fn deinit(self: *Self) void {
    for (self.denoisers) |*d| d.deinit();
    self.allocator.free(self.denoisers);
    self.temp_result_segment.deinit();
    self.buffer.deinit();
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
            .input_segment = input.segment,
            .n_remaining_input = n_remaining_input,
            .denoised_segment = null,
            .metadata = null,
        };
    }

    defer {
        self.buffer.reset(input.segment.index + n_written);
        self.vad_metadata = .{};
    }

    var result_segment: *Segment = &self.temp_result_segment;
    result_segment.index = self.buffer.segment.index;

    var vad_min: f32 = 100;
    for (0..self.n_channels) |i| {
        // FIXME: Each channel should use its own denoiser.
        var vad = try self.denoisers[0].denoise(
            input.segment.channel_pcm_buf[i],
            result_segment.channel_pcm_buf[i].first,
        );

        if (vad < vad_min) vad_min = vad;
    }

    self.vad_metadata.push(
        .{ .rnn_vad = vad_min },
        result_segment.length,
    );

    const result = Result{
        .input_segment = input.segment,
        .denoised_segment = result_segment,
        .metadata = self.vad_metadata.toResult(),
        .n_remaining_input = n_remaining_input,
    };

    return result;
}

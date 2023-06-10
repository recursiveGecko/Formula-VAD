const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const VADMetadata = @import("./VADMetadata.zig");
const BufferedStep = @import("./BufferedStep.zig");
const NSNet2 = @import("../NSNet2.zig");

const Self = @This();
pub const Result = struct {
    input_segment: *const Segment,
    denoised_segment: ?*const Segment,
    n_remaining_input: usize,
    metadata: ?VADMetadata.Result,
};

allocator: Allocator,
n_channels: usize,
sample_rate: usize,
denoisers: []NSNet2,
buffer: SegmentWriter,
vad_metadata: VADMetadata = .{},
temp_result_segment: Segment,

pub fn init(
    allocator: Allocator,
    n_channels: usize,
    sample_rate: usize,
) !Self {
    const temp_result_segment = try Segment.initWithCapacity(
        allocator,
        n_channels,
        getChunkSizeForSR(sample_rate),
    );

    var denoisers = try allocator.alloc(NSNet2, n_channels);
    for (0..n_channels) |i| {
        denoisers[i] = try NSNet2.init(allocator, sample_rate);
    }
    errdefer {
        for (0..n_channels) |i| denoisers[i].deinit();
        allocator.free(denoisers);
    }

    var buffer = try SegmentWriter.init(allocator, n_channels, getChunkSizeForSR(sample_rate));
    errdefer buffer.deinit();

    return Self{
        .allocator = allocator,
        .n_channels = n_channels,
        .sample_rate = sample_rate,
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

pub fn getChunkSize(self: *Self) usize {
    return getChunkSizeForSR(self.sample_rate);
}

pub fn getChunkSizeForSR(sample_rate: usize) usize {
    return NSNet2.getChunkSize(sample_rate);
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

    for (0..self.n_channels) |i| {
        try self.denoisers[i].denoise(
            self.buffer.segment.channel_pcm_buf[i],
            result_segment.channel_pcm_buf[i].first,
        );
    }

    const result = Result{
        .input_segment = input.segment,
        .denoised_segment = result_segment,
        .metadata = self.vad_metadata.toResult(),
        .n_remaining_input = n_remaining_input,
    };

    return result;
}

const MultiRingBuffer = @import("./structures/MultiRingBuffer.zig").MultiRingBuffer;
const Segment = @import("./AudioPipeline/Segment.zig");
const BufferedStep = @import("./AudioPipeline/BufferedStep.zig");

pub const AudioMRB = MultiRingBuffer(f32, u64);
pub const SampleIndex = u64;

const SplitSegments = struct {
    first: Segment,
    second: Segment,
};

pub fn splitSliceToSegments(split_slice: *const AudioMRB.SplitSlice) SplitSegments {
    return .{
        .first = Segment{
            .index = split_slice.first_index,
            .channel_pcm_buf = split_slice.first,
            .mem_ownership = .nothing,
        },
        .second = Segment{
            .index = split_slice.second_index,
            .channel_pcm_buf = split_slice.second,
            .mem_ownership = .nothing,
        },
    };
}

const SplitBufferedSteps = struct {
    first: BufferedStep.Result,
    second: BufferedStep.Result,
};

pub fn splitSegmentsToBufferedSteps(split_segments: *const SplitSegments) SplitBufferedSteps {
    return .{
        .first = BufferedStep.Result{ .segment = &split_segments.first, .metadata = .{} },
        .second = BufferedStep.Result{ .segment = &split_segments.second, .metadata = .{} },
    };
}

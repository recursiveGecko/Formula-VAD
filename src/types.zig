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
        .first = Segment.wrapChannelPcmBuf(split_slice.first_index, split_slice.first),
        .second = Segment.wrapChannelPcmBuf(split_slice.second_index, split_slice.second),
    };
}

const SplitBufferedSteps = struct {
    first: BufferedStep.Result,
    second: BufferedStep.Result,
};

pub fn splitSegmentsToBufferedSteps(split_segments: *const SplitSegments) SplitBufferedSteps {
    return .{
        .first = BufferedStep.Result.wrapSegment(split_segments.first),
        .second = BufferedStep.Result.wrapSegment(split_segments.second),
    };
}

const Segment = @import("./Segment.zig");
const VADMetadata = @import("./VADMetadata.zig");

pub const Result = struct {
    segment: *const Segment,
    metadata: VADMetadata.Result,
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const SpeechSegment = @import("./SpeechSegment.zig");
const Evaluator = @import("../Evaluator.zig");

pub fn parseAudacitySegments(
    allocator: Allocator,
    txt: []const u8,
    side: SpeechSegment.Side,
) ![]SpeechSegment {
    var segments: ArrayList(SpeechSegment) = .empty;
    errdefer segments.deinit(allocator);

    const no_cr = try std.mem.replaceOwned(u8, allocator, txt, "\r", "");
    defer allocator.free(no_cr);

    var lines = std.mem.splitScalar(u8, no_cr, '\n');

    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');

        const from_str = fields.next() orelse continue;
        const to_str = fields.next() orelse continue;
        // var comment = fields.next() orelse continue;

        const from: f32 = try std.fmt.parseFloat(f32, from_str);
        const to: f32 = try std.fmt.parseFloat(f32, to_str);

        const segment = SpeechSegment{
            .from_sec = from,
            .to_sec = to,
            .side = side,
        };

        try segments.append(allocator, segment);
    }

    return segments.toOwnedSlice(allocator);
}

pub fn serializeResultToAudacity(allocator: Allocator, result: Evaluator.Result) ![]const u8 {
    var contents_array: std.ArrayList(u8) = .empty;
    var writer = contents_array.writer(allocator);
    defer contents_array.deinit(allocator);

    for (result.input_segments) |segment| {
        const comment = try segment.toComment(allocator);
        defer allocator.free(comment);

        try writer.print("{d:.4}\t{d:.4}\t{s}\n", .{ segment.from_sec, segment.to_sec, comment });
    }

    for (result.ref_segments) |ref_segment| {
        if (ref_segment.hasMatch()) continue;

        const comment = try std.fmt.allocPrint(allocator, "missed {s}", .{ref_segment.debug_info orelse ""});
        defer allocator.free(comment);

        try writer.print("{d:.4}\t{d:.4}\t{s}\n", .{ ref_segment.from_sec, ref_segment.to_sec, comment });
    }

    return contents_array.toOwnedSlice(allocator);
}

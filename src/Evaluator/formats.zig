const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const SpeechSegment = @import("./SpeechSegment.zig");
const Evaluator = @import("../Evaluator.zig");

pub fn parseAudacitySegments(allocator: Allocator, txt: []const u8) ![]SpeechSegment {
    var segments = ArrayList(SpeechSegment).init(allocator);
    errdefer segments.deinit();

    const no_cr = try std.mem.replaceOwned(u8, allocator, txt, "\r", "");
    defer allocator.free(no_cr);

    var lines = std.mem.split(u8, txt, "\n");

    while (lines.next()) |line| {
        var fields = std.mem.split(u8, line, "\t");

        var from_str = fields.next() orelse continue;
        var to_str = fields.next() orelse continue;
        // var comment = fields.next() orelse continue;

        var from: f32 = try std.fmt.parseFloat(f32, from_str);
        var to: f32 = try std.fmt.parseFloat(f32, to_str);

        const segment = SpeechSegment{
            .from_sec = from,
            .to_sec = to,
            .side = .ref,
        };

        try segments.append(segment);
    }

    return segments.toOwnedSlice();
}

pub fn serializeEvaluatorToAudacityTxt(allocator: Allocator, evaluator: Evaluator) ![]const u8 {
    var contents_array = std.ArrayList(u8).init(allocator);
    var writer = contents_array.writer();
    defer contents_array.deinit();

    for (evaluator.input_segments) |segment| {
        const comment = try segment.toComment(allocator);
        defer allocator.free(comment);

        try writer.print("{d:.4}\t{d:.4}\t{s}\n", .{ segment.from_sec, segment.to_sec, comment });
    }

    for (evaluator.reference_segments) |ref_segment| {
        if (ref_segment.hasMatch()) continue;
        try writer.print("{d:.4}\t{d:.4}\t{s}\n", .{ ref_segment.from_sec, ref_segment.to_sec, "missed" });
    }

    return contents_array.toOwnedSlice();
}

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const clap = @import("clap");

const exit = std.os.exit;
var stderr = std.io.getStdErr();
var stdout = std.io.getStdOut();

pub const SpeechSegment = struct {
    const Match = enum {
        unmatched,
        matched,
    };

    from_sec: f32,
    to_sec: f32,

    match: Match = .unmatched,
    // TODO: Not implemented
    overlap: ?f32 = null,
    // TODO: Not implemented
    start_delta: ?f32 = null,
    // TODO: Not implemented
    end_delta: ?f32 = null,

    pub fn duration(self: SpeechSegment) f32 {
        return self.to_sec - self.from_sec;
    }

    pub fn overlapWith(self: SpeechSegment, other: SpeechSegment) f32 {
        const max_from = @max(self.from_sec, other.from_sec);
        const min_to = @min(self.to_sec, other.to_sec);

        return min_to - max_from;
    }
};

pub const Stats = struct {
    total_input_events: usize = 0,
    total_reference_events: usize = 0,
    true_positives: usize = 0,
    true_positive_rate: f32 = 0,
    false_positives: usize = 0,
    false_positive_rate: f32 = 0,
    false_negatives: usize = 0,
    false_negative_rate: f32 = 0,
};

const Self = @This();

allocator: Allocator,
input_segments: []SpeechSegment,
reference_segments: []SpeechSegment,

pub fn initAndRun(
    allocator: Allocator,
    input: []const SpeechSegment,
    reference: []const SpeechSegment,
) !Self {
    const input_copy = try allocator.alloc(SpeechSegment, input.len);
    errdefer allocator.free(input_copy);

    const reference_copy = try allocator.alloc(SpeechSegment, reference.len);
    errdefer allocator.free(reference_copy);

    @memcpy(input_copy, input);
    @memcpy(reference_copy, reference);

    var self = Self{
        .allocator = allocator,
        .input_segments = input_copy,
        .reference_segments = reference_copy,
    };

    for (self.input_segments) |*input_segment| {
        const overlapping_segments = try self.findOverlapping(input_segment.*, self.reference_segments);
        defer self.allocator.free(overlapping_segments);

        if (overlapping_segments.len > 0) {
            input_segment.match = .matched;
        }

        for (overlapping_segments) |segment| {
            segment.match = .matched;
        }
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.input_segments);
    self.allocator.free(self.reference_segments);
}

fn findOverlapping(self: *Self, target: SpeechSegment, others: []SpeechSegment) ![]*SpeechSegment {
    var overlapping = ArrayList(*SpeechSegment).init(self.allocator);
    errdefer overlapping.deinit();

    for (others) |*other| {
        if (target.overlapWith(other.*) > 0.0) {
            try overlapping.append(other);
        }
    }

    return overlapping.toOwnedSlice();
}

// TODO: This is pretty shaky since it doesn't take overlap into account
// and the fact that one VAD segment could correspond to multiple reference 
// segments and vice versa.
// Contributions welcome.
pub fn buildStatistics(self: *Self) Stats {
    var stats = Stats{
        .total_input_events = self.input_segments.len,
        .total_reference_events = self.reference_segments.len,
    };

    for (self.input_segments) |segment| {
        if (segment.match == .unmatched) stats.false_positives += 1;
        if (segment.match == .matched) stats.true_positives += 1;
    }

    for (self.reference_segments) |segment| {
        if (segment.match == .unmatched) stats.false_negatives += 1;
    }

    stats.true_positive_rate = @intToFloat(f32, stats.true_positives) / @intToFloat(f32, stats.total_input_events);
    stats.false_positive_rate = @intToFloat(f32, stats.false_positives) / @intToFloat(f32, stats.total_input_events);
    stats.false_negative_rate = @intToFloat(f32, stats.false_negatives) / @intToFloat(f32, stats.total_reference_events);

    return stats;
}

const params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    \\-i, --input <str>      Input file to evaluate.
    \\-r, --reference <str>  Reference file to evaluate against.
    \\
);

fn printHelp() !void {
    try clap.help(stdout.writer(), clap.Help, &params, .{});
}

/// Entrypoint for CLI invocation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
    }) catch |err| {
        try printHelp();
        diag.report(stderr.writer(), err) catch {};
        exit(1);
    };
    defer res.deinit();

    if (res.args.help == 1) {
        try printHelp();
        return;
    }

    const input_file_path = res.args.input;
    const ref_file_path = res.args.reference;

    if (input_file_path == null or ref_file_path == null) {
        try printHelp();
        exit(1);
    }

    const megabyte = 1024 * 1024;

    const input_contents = try fs.Dir.readFileAlloc(fs.cwd(), allocator, input_file_path.?, 10 * megabyte);
    defer allocator.free(input_contents);

    const ref_contents = try fs.Dir.readFileAlloc(fs.cwd(), allocator, ref_file_path.?, 10 * megabyte);
    defer allocator.free(ref_contents);

    const input_segments = try parseAudacityTxt(allocator, ref_contents);
    defer allocator.free(input_segments);

    const ref_segments = try parseAudacityTxt(allocator, ref_contents);
    defer allocator.free(ref_segments);

    var evaluator = try Self.initAndRun(allocator, input_segments, ref_segments);
    defer evaluator.deinit();

    const stats = evaluator.buildStatistics();
    std.debug.print("{any}", .{stats});
}

pub fn parseAudacityTxt(allocator: Allocator, txt: []const u8) ![]SpeechSegment {
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
        };

        try segments.append(segment);
    }

    return segments.toOwnedSlice();
}

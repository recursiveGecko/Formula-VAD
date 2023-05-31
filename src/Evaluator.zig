const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const clap = @import("clap");
pub const SpeechSegment = @import("./Evaluator/SpeechSegment.zig");
pub const statistics = @import("./Evaluator/statistics.zig");
pub const formats = @import("./Evaluator/formats.zig");
pub const report_generator = @import("./simulator/report_generator.zig");
const exit = std.os.exit;
const stderr = std.io.getStdErr();
const stdout = std.io.getStdOut();
const megabyte = 1024 * 1024;

const Self = @This();
allocator: Allocator,
input_segments: []SpeechSegment,
reference_segments: []SpeechSegment,

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
    var stdout_w = stdout.writer();

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

    const input_segments = try readParseAudacitySegments(allocator, input_file_path.?);
    defer allocator.free(input_segments);

    const ref_segments = try readParseAudacitySegments(allocator, ref_file_path.?);
    defer allocator.free(ref_segments);

    var evaluator = try Self.initAndRun(allocator, input_segments, ref_segments);
    defer evaluator.deinit();

    const stat_config = statistics.StatConfig{
        // TODO: Make this configurable?
        // it should match whatever the VAD algorithm uses by design
        // for most accurate results
        .ignore_shorter_than_sec = 0.7,
    };

    const stats = try statistics.fromEvaluator(evaluator, stat_config);
    try stdout_w.print("\n=> Definitions: \n\n", .{});
    try stdout_w.writeAll(report_generator.definitions);
    try stdout_w.print("\n\n=> Report: \n\n", .{});
    try stdout_w.print("Total speech duration  (P):  {d: >5.1} sec\n", .{stats.total_positives_sec});
    try stdout_w.print("True positives        (TP):  {d: >5.1} sec\n", .{stats.true_positives_sec});
    try stdout_w.print("False positives       (FP):  {d: >5.1} sec\n", .{stats.false_positives_sec});
    try stdout_w.print("False negatives       (FN):  {d: >5.1} sec\n", .{stats.false_negatives_sec});
    try stdout_w.print("True positive rate   (TPR):  {d: >6.2} %\n", .{stats.true_positive_rate * 100});
    try stdout_w.print("False negative rate  (FNR):  {d: >6.2} %\n", .{stats.false_negative_rate * 100});
    try stdout_w.print("Precision            (PPV):  {d: >6.2} %\n", .{stats.precision * 100});
    try stdout_w.print("False discovery rate (FDR):  {d: >6.2} %\n", .{stats.false_discovery_rate * 100});
}

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

    std.mem.sort(SpeechSegment, input_copy, {}, SpeechSegment.sortByStart);
    std.mem.sort(SpeechSegment, reference_copy, {}, SpeechSegment.sortByStart);

    for(0..input_copy.len) |i| input_copy[i].id = @intCast(i64, i + 1);
    for(0..reference_copy.len) |i| reference_copy[i].id = @intCast(i64, i + 1);

    var prev: ?*SpeechSegment = null;
    for (self.input_segments) |*input_segment| {
        const overlapping: []*SpeechSegment = try SpeechSegment.findOverlapping(
            self.allocator,
            input_segment,
            self.reference_segments,
        );
        input_segment.opposite_segments = overlapping;

        for (overlapping) |opposite| {
            const overlap_sec = SpeechSegment.overlapWith(input_segment.*, opposite.*);
            std.debug.assert(overlap_sec > 0.0);
        }

        input_segment.prev = prev;
        if (prev) |prev_| prev_.next = input_segment;
        prev = input_segment;
    }

    prev = null;

    for (self.reference_segments) |*ref_segment| {
        const overlapping: []*SpeechSegment = try SpeechSegment.findOverlapping(
            self.allocator,
            ref_segment,
            self.input_segments,
        );
        ref_segment.opposite_segments = overlapping;

        for (overlapping) |opposite| {
            const overlap_sec = SpeechSegment.overlapWith(ref_segment.*, opposite.*);
            std.debug.assert(overlap_sec > 0.0);
        }

        ref_segment.prev = prev;
        if (prev) |prev_| prev_.next = ref_segment;
        prev = ref_segment;
    }

    return self;
}

pub fn deinit(self: *Self) void {
    for (self.input_segments) |s| {
        if (s.opposite_segments) |opposite_segments| {
            self.allocator.free(opposite_segments);
        }
    }

    for (self.reference_segments) |s| {
        if (s.opposite_segments) |opposite_segments| {
            self.allocator.free(opposite_segments);
        }
    }

    self.allocator.free(self.input_segments);
    self.allocator.free(self.reference_segments);
}

pub fn readParseAudacitySegments(allocator: Allocator, path: []const u8) ![]SpeechSegment {
    const ref_contents = try fs.Dir.readFileAlloc(fs.cwd(), allocator, path, 10 * megabyte);
    defer allocator.free(ref_contents);

    const ref_segments = try formats.parseAudacitySegments(allocator, ref_contents);
    errdefer allocator.free(ref_segments);

    return ref_segments;
}

test {
    _ = statistics;
}
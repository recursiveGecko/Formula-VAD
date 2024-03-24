const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const clap = @import("clap");
pub const SpeechSegment = @import("./Evaluator/SpeechSegment.zig");
pub const statistics = @import("./Evaluator/statistics.zig");
pub const formats = @import("./Evaluator/formats.zig");
pub const report_generator = @import("./simulator/report_generator.zig");
const exit = std.process.exit;
const stderr = std.io.getStdErr();
const stdout = std.io.getStdOut();
const megabyte = 1024 * 1024;

const params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\-i, --input <path>      Input file to evaluate.
    \\-r, --reference <path>  Reference file to evaluate against.
    \\-f, --format <format>   Output format, 'plain' or 'json'
    \\
);

const ResultJson = struct {
    P: f32,
    TP: f32,
    FP: f32,
    FP_COUNT: u32,
    FN_COUNT: u32,
    FN: f32,
    TPR: f32,
    PPV: f32,
    FNR: f32,
    FDR: f32,
};

const Self = @This();
allocator: Allocator,
input_segments: []SpeechSegment,
reference_segments: []SpeechSegment,

/// Entrypoint for CLI invocation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    var stdout_w = stdout.writer();

    const arg_parsers = .{
        .path = clap.parsers.string,
        .format = clap.parsers.enumeration(enum { plain, json }),
    };

    var diag = clap.Diagnostic{};
    var clap_res = clap.parse(clap.Help, &params, arg_parsers, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try printHelp();
        diag.report(stderr.writer(), err) catch {};
        exit(1);
    };
    defer clap_res.deinit();

    const args = clap_res.args;

    if (args.help == 1) {
        try printHelp();
        return;
    }

    const format = args.format orelse .plain;

    const input_file_path = args.input;
    const ref_file_path = args.reference;

    if (input_file_path == null or ref_file_path == null) {
        try printHelp();
        exit(1);
    }

    const input_segments = try readParseAudacitySegments(allocator, input_file_path.?, SpeechSegment.Side.vad);
    defer allocator.free(input_segments);

    const ref_segments = try readParseAudacitySegments(allocator, ref_file_path.?, SpeechSegment.Side.ref);
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

    switch (format) {
        .plain => {
            try stdout_w.print("\n=> Definitions: \n\n", .{});
            try stdout_w.writeAll(report_generator.definitions);
            try stdout_w.print("\n\n=> Report: \n\n", .{});
            try stdout_w.print("Total speech duration  (P):  {d: >5.1} sec\n", .{stats.total_positives_sec});
            try stdout_w.print("True positives        (TP):  {d: >5.1} sec\n", .{stats.true_positives_sec});
            try stdout_w.print("False positives       (FP):  {d: >5.1} sec\n", .{stats.false_positives_sec});
            try stdout_w.print("False negatives       (FN):  {d: >5.1} sec\n", .{stats.false_negatives_sec});
            try stdout_w.print("True positive rate   (TPR):  {d: >6.2} %\n", .{stats.true_positive_rate * 100});
            try stdout_w.print("Precision            (PPV):  {d: >6.2} %\n", .{stats.precision * 100});
            try stdout_w.print("False negative rate  (FNR):  {d: >6.2} %\n", .{stats.false_negative_rate * 100});
            try stdout_w.print("False discovery rate (FDR):  {d: >6.2} %\n", .{stats.false_discovery_rate * 100});
        },
        .json => {
            const res = ResultJson{
                .P = stats.total_positives_sec,
                .TP = stats.true_positives_sec,
                .FP = stats.false_positives_sec,
                .FN = stats.false_negatives_sec,
                .FP_COUNT = stats.false_positives_count,
                .FN_COUNT = stats.false_negatives_count,
                .TPR = stats.true_positive_rate,
                .PPV = stats.precision,
                .FNR = stats.false_negative_rate,
                .FDR = stats.false_discovery_rate,
            };

            try std.json.stringify(res, .{}, stdout_w);
            try stdout_w.writeAll("\n");
        },
    }
}

fn printHelp() !void {
    try clap.help(stdout.writer(), clap.Help, &params, .{});
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

    const self = Self{
        .allocator = allocator,
        .input_segments = input_copy,
        .reference_segments = reference_copy,
    };

    std.mem.sort(SpeechSegment, input_copy, {}, SpeechSegment.sortByStart);
    std.mem.sort(SpeechSegment, reference_copy, {}, SpeechSegment.sortByStart);

    for (0..input_copy.len) |i| input_copy[i].id = @intCast(i + 1);
    for (0..reference_copy.len) |i| reference_copy[i].id = @intCast(i + 1);

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

pub fn readParseAudacitySegments(
    allocator: Allocator,
    path: []const u8,
    side: SpeechSegment.Side,
) ![]SpeechSegment {
    const ref_contents = try fs.Dir.readFileAlloc(fs.cwd(), allocator, path, 10 * megabyte);
    defer allocator.free(ref_contents);

    const ref_segments = try formats.parseAudacitySegments(allocator, ref_contents, side);
    errdefer allocator.free(ref_segments);

    return ref_segments;
}

test {
    _ = statistics;
}

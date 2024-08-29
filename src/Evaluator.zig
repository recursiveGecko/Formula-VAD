const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const clap = @import("clap");
pub const SpeechSegment = @import("./Evaluator/SpeechSegment.zig");
pub const statistics = @import("./Evaluator/statistics.zig");
pub const formats = @import("./Evaluator/formats.zig");
pub const report_generator = @import("./simulator/report_generator.zig");
const simulator = @import("./simulator.zig");
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

/// Entrypoint for CLI invocation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    var stdout_w = stdout.writer();

    const arg_parsers = .{
        .path = clap.parsers.string,
        .format = clap.parsers.enumeration(report_generator.Format),
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

    var stat_config = simulator.static_sim_config.stat_config;
    // TODO: Make configurable
    stat_config.ignore_shorter_than_sec = 0.7;

    const result = try evaluate(allocator, stat_config, input_segments, ref_segments);
    const stats = result.stats;

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

pub const Result = struct {
    allocator: Allocator,
    /// Name must be freed by the caller who assigns it.
    name: ?[]const u8 = null,
    input_segments: []const SpeechSegment,
    ref_segments: []const SpeechSegment,
    stats: statistics.SingleStats,

    pub fn deinit(self: *Result) void {
        for (self.input_segments) |s| {
            if (s.opposite_segments) |opposite_segments| self.allocator.free(opposite_segments);
        }
        for (self.ref_segments) |s| {
            if (s.opposite_segments) |opposite_segments| self.allocator.free(opposite_segments);
        }
        self.allocator.free(self.input_segments);
        self.allocator.free(self.ref_segments);
    }

    pub fn serializeToAudacity(self: *const Result, allocator: std.mem.Allocator) ![]const u8 {
        return formats.serializeResultToAudacity(allocator, self.*);
    }
};

pub fn evaluate(
    allocator: Allocator,
    stat_config: statistics.StatConfig,
    input_: []const SpeechSegment,
    reference_: []const SpeechSegment,
) !Result {
    const input_segments = try allocator.alloc(SpeechSegment, input_.len);
    const ref_segments = try allocator.alloc(SpeechSegment, reference_.len);

    @memcpy(input_segments, input_);
    @memcpy(ref_segments, reference_);

    std.mem.sort(SpeechSegment, input_segments, {}, SpeechSegment.sortByStart);
    std.mem.sort(SpeechSegment, ref_segments, {}, SpeechSegment.sortByStart);

    for (0..input_segments.len) |i| input_segments[i].id = @intCast(i + 1);
    for (0..ref_segments.len) |i| ref_segments[i].id = @intCast(i + 1);

    var prev: ?*SpeechSegment = null;
    for (input_segments) |*input_segment| {
        const overlapping: []*SpeechSegment = try SpeechSegment.findOverlapping(
            allocator,
            input_segment,
            ref_segments,
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

    for (ref_segments) |*ref_segment| {
        const overlapping: []*SpeechSegment = try SpeechSegment.findOverlapping(
            allocator,
            ref_segment,
            input_segments,
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

    const stats = try statistics.calculate(allocator, stat_config, input_segments, ref_segments);
    return Result{
        .allocator = allocator,
        .input_segments = input_segments,
        .ref_segments = ref_segments,
        .stats = stats,
    };
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

const t = std.testing;

test "Evaluator/statistics integration test" {
    var ref_segments = [_]SpeechSegment{
        SpeechSegment{
            .side = .ref,
            .id = 1,
            .from_sec = 2,
            .to_sec = 4,
        },
        SpeechSegment{
            .side = .ref,
            .id = 2,
            .from_sec = 5,
            .to_sec = 7,
        },
        SpeechSegment{
            .side = .ref,
            .id = 3,
            .from_sec = 10,
            .to_sec = 20,
        },
    };

    var detected_segments = [_]SpeechSegment{
        SpeechSegment{
            .side = .vad,
            .id = 1,
            // 1.5 seconds too early
            .from_sec = 0.5,
            // 0.5s too late
            .to_sec = 4.5,
        },
        SpeechSegment{
            .side = .vad,
            .id = 2,
            // 1s late
            .from_sec = 6,
            // exact
            .to_sec = 7,
        },
        SpeechSegment{
            .side = .vad,
            .id = 3,
            // exact
            .from_sec = 10,
            // 3s "early", continued...
            .to_sec = 12,
        },
        SpeechSegment{
            .side = .vad,
            .id = 4,
            // ... continued after 2s
            .from_sec = 14,
            // exact
            .to_sec = 20,
        },
        SpeechSegment{
            .side = .vad,
            .id = 5,
            // false detection
            .from_sec = 100,
            .to_sec = 100.3,
        },
        SpeechSegment{
            .side = .vad,
            .id = 6,
            // 2nd false detection
            .from_sec = 101,
            .to_sec = 101.3,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result = try evaluate(
        arena.allocator(),
        .{
            .ignore_shorter_than_sec = 0,
            .fill_gaps_limit_sec = 0.1,
            .fp_start_grace_sec = 2,
            .fp_end_grace_sec = 2,
        },
        &detected_segments,
        &ref_segments,
    );
    defer result.deinit();

    // std.debug.print("stats: {any}\n", .{result.stats});

    // detected segment starting 1.5s too early and ending 0.5s too late adds 2s to total positives (ref segments are 14s long)
    try t.expectApproxEqAbs(16, result.stats.total_positives_sec, 0.01);

    try t.expectApproxEqAbs(13, result.stats.true_positives_sec, 0.01);
    try t.expectEqual(4, result.stats.true_positives_count);

    // 0.3s, 0.3s FP
    try t.expectApproxEqAbs(0.6, result.stats.false_positives_sec, 0.01);
    try t.expectEqual(2, result.stats.false_positives_count);

    // 1s late start; 2s gap
    try t.expectApproxEqAbs(3, result.stats.false_negatives_sec, 0.01);
    try t.expectEqual(2, result.stats.false_negatives_count);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Simulation = @import("../simulator.zig").Simulation;
const Evaluator = @import("../Evaluator.zig");
const statistics = @import("../Evaluator/statistics.zig");
const SingleStats = statistics.SingleStats;
const AggregateStats = statistics.AggregateStats;
const StatConfig = statistics.StatConfig;

pub const Format = enum { plain, json };

pub const definitions =
    \\P   (Positives):                            Total duration of real speech segments (from reference labels)
    \\TP  (True positives):                       Duration of correctly detected speech segments
    \\FP  (False positives):                      Duration or number of incorrectly detected speech segments
    \\FN  (False negatives):                      Duration or number of missed speech segments
    \\TPR (True positive rate, sensitivity):      Probability that VAD detects real speech.  = 1 - FNR
    \\PPV (Precision, Positive predictive value): Probability that detected speech is real.  = 1 - FDR
    \\FDR (False discovery rate):                 Probability that detected speech is false. = FP / (TP + FP) 
    \\FNR (False negative rate, miss rate):       Probability that VAD misses speech.        = FN / P 
;

pub const table_header_fmt = "| {s: >30} | {s: >4} | {s: >4} | {s: >6} | {s: >6} | {s: >6} | {s: >6} | {s: >6} | {s: >6} | {s: >6} |\n";
pub const table_header_vals = .{ "Name", "P/s", "TP/s", "FP/s", "FN/s", "TP/#", "FP/#", "FN/#", "FDR/s", "FNR/s" };

pub const table_separator_fmt = "| {s:->30} | {s:->4} | {s:->4} | {s:->6} | {s:->6} | {s:->6} | {s:->6} | {s:->6} | {s:->6} | {s:->6} |\n";
pub const table_separator_vals = .{ "", "", "", "", "", "", "", "", "", "" };

pub const table_row_fmt = "| {s: <30} | {d: >4.0} | {d: >4.0} | {d: >6.0} | {d: >6.0} | {d: >6.0} | {d: >6.0} | {d: >6.0} | {d: >5.1}% | {d: >5.1}% |\n";

pub fn bufPrintSimulationReport(
    allocator: Allocator,
    eval_results: []Evaluator.Result,
    /// TODO
    format: Format,
) ![]const u8 {
    _ = format; // autofix

    var array_buf = ArrayList(u8).init(allocator);
    const writer = array_buf.writer();

    // Aggregate results and print them
    var all_stats_list = std.ArrayList(SingleStats).init(allocator);
    errdefer all_stats_list.deinit();

    try writer.print("\n\n=> Definitions\n\n{s}", .{definitions});
    try writer.print("\n\n=> Performance Report\n\n", .{});
    try writer.print(table_header_fmt, table_header_vals);
    try writer.print(table_separator_fmt, table_separator_vals);

    for (eval_results) |result| {
        const stats = result.stats;
        try all_stats_list.append(stats);

        try writer.print(table_row_fmt, .{
            result.name orelse "<null>",
            stats.total_positives_sec,
            stats.true_positives_sec,
            stats.false_positives_sec,
            stats.false_negatives_sec,
            stats.true_positives_count,
            stats.false_positives_count,
            stats.false_negatives_count,
            stats.false_discovery_rate * 100,
            stats.false_negative_rate * 100,
        });
    }

    const all_stats = try all_stats_list.toOwnedSlice();
    defer allocator.free(all_stats);

    const agg = statistics.aggregate(all_stats);

    try writer.print("\n=> Aggregate stats \n\n", .{});
    try writer.print("Total speech duration  (P/s): {d: >7.1} sec\n", .{agg.total_positives_sec});
    try writer.print("True positives        (TP/s): {d: >7.1} sec\n", .{agg.true_positives_sec});
    try writer.print("False positives sec.  (FP/s): {d: >7.1} sec\n", .{agg.false_positives_sec});
    try writer.print("False negatives sec.  (FN/s): {d: >7.1} sec\n", .{agg.false_negatives_sec});
    try writer.print("True positives        (TP/#): {d: >7.1} x\n", .{agg.true_positives_count});
    try writer.print("False positives #     (FP/#): {d: >7.1} x\n", .{agg.false_positives_count});
    try writer.print("False negatives #     (FN/#): {d: >7.1} x", .{agg.false_negatives_count});
    try writer.print("      Min.    Avg.    Max. \n", .{});
    try writer.print(
        "True positive rate   (TPR/s):   {d: >5.1}%  |  {d: >5.1}% /{d: >5.1}% /{d: >5.1}% \n",
        .{
            agg.true_positive_rate.overall * 100,
            agg.true_positive_rate.min * 100,
            agg.true_positive_rate.avg * 100,
            agg.true_positive_rate.max * 100,
        },
    );
    try writer.print(
        "Precision            (PPV/s):   {d: >5.1}%  |  {d: >5.1}% /{d: >5.1}% /{d: >5.1}% \n",
        .{
            agg.precision.overall * 100,
            agg.precision.min * 100,
            agg.precision.avg * 100,
            agg.precision.max * 100,
        },
    );
    try writer.print(
        "False discovery rate (FDR/s):   {d: >5.1}%  |  {d: >5.1}% /{d: >5.1}% /{d: >5.1}% \n",
        .{
            agg.false_discovery_rate.overall * 100,
            agg.false_discovery_rate.min * 100,
            agg.false_discovery_rate.avg * 100,
            agg.false_discovery_rate.max * 100,
        },
    );
    try writer.print(
        "False negative rate  (FNR/s):   {d: >5.1}%  |  {d: >5.1}% /{d: >5.1}% /{d: >5.1}% \n",
        .{
            agg.false_negative_rate.overall * 100,
            agg.false_negative_rate.min * 100,
            agg.false_negative_rate.avg * 100,
            agg.false_negative_rate.max * 100,
        },
    );
    try writer.print("F-Score (β = {d: >5.2})         :   {d: >5.1}% \n", .{ agg.f_score_beta, agg.f_score * 100 });
    try writer.print("Fowlkes-Mallows index       :   {d: >5.1}% \n", .{agg.fm_index * 100});

    return array_buf.toOwnedSlice();
}

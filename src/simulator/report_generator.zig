const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Simulation = @import("../simulator.zig").Simulation;
const statistics = @import("../Evaluator/statistics.zig");
const SingleStats = statistics.SingleStats;
const AggregateStats = statistics.AggregateStats;

pub const definitions =
    \\P   (Positives):                            Total number of real speech segments (from reference labels)
    \\TP  (True positives):                       Number of correctly detected speech segments
    \\FP  (False positives):                      Number of incorrectly detected speech segments
    \\FN  (False negatives):                      Number of missed speech segments
    \\TPR (True positive rate, sensitivity):      Probability that VAD detects a real speech segment. = TP / P 
    \\FNR (False negative rate, miss rate):       Probability that VAD misses a speech segment.       = FN / P 
    \\PPV (Precision, Positive predictive value): Probability that detected speech segment is true.   = TP / (TP + FP) 
    \\FDR (False discovery rate):                 Probability that detected speech segment is false.  = FP / (TP + FP) 
;

pub const table_header_fmt = "| {s: >30} | {s: >3} | {s: >3} | {s: >3} | {s: >3} | {s: >6} | {s: >6} | {s: >6} | {s: >8} |\n";
pub const table_header_vals = .{ "Name", "P", "TP", "FP", "FN", "TPR", "FNR", "PPV", "FDR (!)" };

pub const table_separator_fmt = "| {s:->30} | {s:->3} | {s:->3} | {s:->3} | {s:->3} | {s:->6} | {s:->6} | {s:->6} | {s:->8} |\n";
pub const table_separator_vals = .{ "", "", "", "", "", "", "", "", "" };

pub const table_row_fmt = "| {s: >30} | {d: >3} | {d: >3} | {d: >3} | {d: >3} | {d: >5.1}% | {d: >5.1}% | {d: >5.1}% | {d: >7.1}% |\n";

pub fn bufPrintSimulationReport(allocator: Allocator, simulation: Simulation) ![]const u8 {
    var array_buf = ArrayList(u8).init(allocator);
    const writer = array_buf.writer();

    // Aggregate results and print them
    var all_stats_list = std.ArrayList(SingleStats).init(allocator);
    errdefer all_stats_list.deinit();

    try writer.print("\n\n=> Definitions\n\n{s}", .{definitions});
    try writer.print("\n\n=> Performance Report\n\n", .{});
    try writer.print(table_header_fmt, table_header_vals);
    try writer.print(table_separator_fmt, table_separator_vals);

    for (simulation.instances) |instance| {
        if (instance.evaluator) |evaluator| {
            const stats = statistics.fromEvaluator(evaluator);
            try all_stats_list.append(stats);

            try writer.print(table_row_fmt, .{
                instance.name,
                stats.total_positives,
                stats.true_positives,
                stats.false_positives,
                stats.false_negatives,
                stats.true_positive_rate * 100,
                stats.false_negative_rate * 100,
                stats.precision * 100,
                stats.false_discovery_rate * 100,
            });
        }
    }

    const all_stats = try all_stats_list.toOwnedSlice();
    defer allocator.free(all_stats);

    const agg = statistics.aggregate(all_stats);

    try writer.print("\n=> Aggregate stats \n\n", .{});
    try writer.print("Total speech events    (P):  {d: >5}\n", .{agg.total_positives});
    try writer.print("True positives        (TP):  {d: >5}\n", .{agg.true_positives});
    try writer.print("False positives       (FP):  {d: >5}\n", .{agg.false_positives});
    try writer.print("False negatives       (FN):  {d: >5}\n", .{agg.false_negatives});
    try writer.print(
        "True positive rate   (TPR):  {d: >5.1}% /{d: >5.1}% /{d: >5.1}% /{d: >5.1}%  (Min/Max/Avg/Overall)\n",
        .{
            agg.true_positive_rate.min * 100,
            agg.true_positive_rate.max * 100,
            agg.true_positive_rate.avg * 100,
            agg.true_positive_rate.overall * 100,
        },
    );
    try writer.print(
        "False negative rate  (FNR):  {d: >5.1}% /{d: >5.1}% /{d: >5.1}% /{d: >5.1}%  (Min/Max/Avg/Overall)\n",
        .{
            agg.false_negative_rate.min * 100,
            agg.false_negative_rate.max * 100,
            agg.false_negative_rate.avg * 100,
            agg.false_negative_rate.overall * 100,
        },
    );
    try writer.print(
        "Precision            (PPV):  {d: >5.1}% /{d: >5.1}% /{d: >5.1}% /{d: >5.1}%  (Min/Max/Avg/Overall)\n",
        .{
            agg.precision.min * 100,
            agg.precision.max * 100,
            agg.precision.avg * 100,
            agg.precision.overall * 100,
        },
    );
    try writer.print(
        "False discovery rate (FDR):  {d: >5.1}% /{d: >5.1}% /{d: >5.1}% /{d: >5.1}%  (Min/Max/Avg/Overall)\n",
        .{
            agg.false_discovery_rate.min * 100,
            agg.false_discovery_rate.max * 100,
            agg.false_discovery_rate.avg * 100,
            agg.false_discovery_rate.overall * 100,
        },
    );

    return array_buf.toOwnedSlice();
}

const std = @import("std");
const math = std.math;
const pow = std.math.pow;
const Evaluator = @import("../Evaluator.zig");

pub const SingleStats = struct {
    /// P - Number of real speech segments (from reference labels)
    total_positives: usize = 0,
    /// TP - Number of correctly detected speech segments
    true_positives: usize = 0,
    /// FP - Number of incorrectly detected speech segments
    false_positives: usize = 0,
    /// FN - Number of missed speech segments
    false_negatives: usize = 0,
    /// TPR (sensitivity, recall) = TP / P
    /// Probability that VAD detects a real speech segment
    true_positive_rate: f32 = undefined,
    /// FNR (miss rate) = FN / P
    /// Probability that VAD misses a real speech segment
    false_negative_rate: f32 = undefined,
    /// FDR (false discovery rate) = FP / (FP + TP)
    /// Given a positive result, the probability that it is false
    false_discovery_rate: f32 = undefined,
    /// PPV (positive predictive value) = TP / (TP + FP)
    /// Given a positive result, the probability that it is true
    precision: f32 = undefined,
};

pub const AggStat = struct {
    overall: f32 = undefined,
    min: f32 = undefined,
    max: f32 = undefined,
    avg: f32 = undefined,
};

pub const AggregateStats = struct {
    /// P - Number of real speech segments (from reference labels)
    total_positives: usize = 0,
    /// TP - Number of correctly detected speech segments
    true_positives: usize = 0,
    /// FP - Number of incorrectly detected speech segments
    false_positives: usize = 0,
    /// FN - Number of missed speech segments
    false_negatives: usize = 0,
    /// TPR (sensitivity, recall) = TP / P
    /// Probability that VAD detects a speech segment
    true_positive_rate: AggStat = .{ .min = 2, .max = -2, .avg = undefined, .overall = undefined },
    /// FNR (miss rate) = FN / P
    /// Probability that VAD misses a speech segment
    false_negative_rate: AggStat = .{ .min = 2, .max = -2, .avg = undefined, .overall = undefined },
    /// FDR (false discovery rate) = FP / (FP + TP)
    /// Given a positive result, the probability that it is false
    false_discovery_rate: AggStat = .{ .min = 2, .max = -2, .avg = undefined, .overall = undefined },
    /// PPV (positive predictive value, precision) = TP / (TP + FP)
    /// Given a positive result, the probability that it is true
    precision: AggStat = .{ .min = 2, .max = -2, .avg = undefined, .overall = undefined },
    /// Fowlkes–Mallows index (single accuracy measure) FM = sqrt(TPR * PPV)
    /// https://en.wikipedia.org/wiki/Fowlkes%E2%80%93Mallows_index
    fm_index: f32 = undefined,
    /// F-score (single accuracy measure) F_beta = (1 + beta^2) * (PPV * TPR) / (beta^2 * PPV + TPR)
    /// https://en.wikipedia.org/wiki/F-score
    f_score: f32 = undefined,
    /// `beta` is chosen such that recall is considered `beta` times as important as precision
    f_score_beta: f32 = undefined,
};

pub const StatConfig = struct {
    // Ignores false negatives shorter than this value
    ignore_shorter_than_sec: f32 = 0.0,
};

pub fn fromEvaluator(eval: Evaluator, config: StatConfig) SingleStats {
    var stats = SingleStats{};

    for (eval.input_segments) |segment| {
        if (!segment.hasMatch()) {
            stats.false_positives += 1;
        }
    }

    for (eval.reference_segments) |ref_segment| {
        if (ref_segment.duration() < config.ignore_shorter_than_sec) continue;
        stats.total_positives += 1;

        if (ref_segment.hasMatch()) {
            stats.true_positives += 1;
        } else {
            stats.false_negatives += 1;
        }
    }

    const true_positives_f = @intToFloat(f32, stats.true_positives);
    const false_positives_f = @intToFloat(f32, stats.false_positives);
    const false_negatives_f = @intToFloat(f32, stats.false_negatives);
    const total_positives_f = @intToFloat(f32, stats.total_positives);

    stats.true_positive_rate = true_positives_f / total_positives_f;
    stats.false_negative_rate = false_negatives_f / total_positives_f;
    stats.false_discovery_rate = false_positives_f / (false_positives_f + true_positives_f);
    stats.precision = true_positives_f / (true_positives_f + false_positives_f);

    return stats;
}

pub fn aggregate(stats: []SingleStats) AggregateStats {
    var agg = AggregateStats{};

    var sum_true_positive_rate: f32 = 0.0;
    var sum_false_negative_rate: f32 = 0.0;
    var sum_false_discovery_rate: f32 = 0.0;
    var sum_precision: f32 = 0.0;

    for (stats) |s| {
        agg.total_positives += s.total_positives;
        agg.true_positives += s.true_positives;
        agg.false_positives += s.false_positives;
        agg.false_negatives += s.false_negatives;

        sum_true_positive_rate += s.true_positive_rate;
        if (s.true_positive_rate < agg.true_positive_rate.min)
            agg.true_positive_rate.min = s.true_positive_rate;
        if (s.true_positive_rate > agg.true_positive_rate.max)
            agg.true_positive_rate.max = s.true_positive_rate;

        sum_false_negative_rate += s.false_negative_rate;
        if (s.false_negative_rate < agg.false_negative_rate.min)
            agg.false_negative_rate.min = s.false_negative_rate;
        if (s.false_negative_rate > agg.false_negative_rate.max)
            agg.false_negative_rate.max = s.false_negative_rate;

        sum_false_discovery_rate += s.false_discovery_rate;
        if (s.false_discovery_rate < agg.false_discovery_rate.min)
            agg.false_discovery_rate.min = s.false_discovery_rate;
        if (s.false_discovery_rate > agg.false_discovery_rate.max)
            agg.false_discovery_rate.max = s.false_discovery_rate;

        sum_precision += s.precision;
        if (s.precision < agg.precision.min)
            agg.precision.min = s.precision;
        if (s.precision > agg.precision.max)
            agg.precision.max = s.precision;
    }

    const n_stats_f = @intToFloat(f32, stats.len);

    const total_positives_f = @intToFloat(f32, agg.total_positives);
    const true_positives_f = @intToFloat(f32, agg.true_positives);
    const false_positives_f = @intToFloat(f32, agg.false_positives);
    const false_negatives_f = @intToFloat(f32, agg.false_negatives);

    agg.true_positive_rate.overall = true_positives_f / total_positives_f;
    agg.false_negative_rate.overall = false_negatives_f / total_positives_f;
    agg.false_discovery_rate.overall = false_positives_f / (false_positives_f + true_positives_f);
    agg.precision.overall = true_positives_f / (true_positives_f + false_positives_f);

    agg.true_positive_rate.avg = sum_true_positive_rate / n_stats_f;
    agg.false_negative_rate.avg = sum_false_negative_rate / n_stats_f;
    agg.false_discovery_rate.avg = sum_false_discovery_rate / n_stats_f;
    agg.precision.avg = sum_precision / n_stats_f;

    // F_beta = (1 + beta^2) * (PPV * TPR) / (beta^2 * PPV + TPR)
    agg.f_score_beta = 0.7;
    agg.f_score = (1 + pow(f32, agg.f_score_beta, 2)) * (agg.precision.overall * agg.true_positive_rate.overall) /
        (pow(f32, agg.f_score_beta, 2) * agg.precision.overall + agg.true_positive_rate.overall);

    // Fowlkes–Mallows index = sqrt(TPR * PPV)
    agg.fm_index = math.sqrt(agg.true_positive_rate.overall * agg.precision.overall);

    return agg;
}

const std = @import("std");
const math = std.math;
const pow = std.math.pow;
const Allocator = std.mem.Allocator;
const Evaluator = @import("../Evaluator.zig");
const SpeechSegment = @import("SpeechSegment.zig");

pub const SingleStats = struct {
    /// P - Duration of real speech segments (from reference labels)
    total_positives_sec: f32 = 0,
    /// TP - Duration of correctly detected speech segments
    true_positives_sec: f32 = 0,
    /// FP - Duration of incorrectly detected speech segments
    false_positives_sec: f32 = 0,
    /// FN - Duration of missed speech segments
    false_negatives_sec: f32 = 0,
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
    /// Fowlkes–Mallows index (single accuracy measure) FM = sqrt(TPR * PPV)
    /// https://en.wikipedia.org/wiki/Fowlkes%E2%80%93Mallows_index
    fm_index: f32 = undefined,
    /// F-score (single accuracy measure) F_beta = (1 + beta^2) * (PPV * TPR) / (beta^2 * PPV + TPR)
    /// https://en.wikipedia.org/wiki/F-score
    f_score: f32 = undefined,
    /// `beta` is chosen such that recall is considered `beta` times as important as precision
    f_score_beta: f32 = undefined,
};

pub const AggStat = struct {
    overall: f32 = undefined,
    min: f32 = undefined,
    max: f32 = undefined,
    avg: f32 = undefined,
};

pub const AggregateStats = struct {
    /// P - Duration of real speech segments (from reference labels)
    total_positives_sec: f32 = 0,
    /// TP - Duration of correctly detected speech segments
    true_positives_sec: f32 = 0,
    /// FP - Duration of incorrectly detected speech segments
    false_positives_sec: f32 = 0,
    /// FN - Duration of missed speech segments
    false_negatives_sec: f32 = 0,
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
    extrude_start: f32 = 0,
    extrude_end: f32 = 0,
    fill_gaps: f32 = 0,
};

pub fn fromEvaluator(eval: Evaluator, config: StatConfig) !SingleStats {
    var stats = SingleStats{};

    for (eval.input_segments) |segment| {
        stats.false_positives_sec += try calcFalsePositiveSec(eval.allocator, segment, config);
        const true_positives_sec = try calcTruePositiveSec(eval.allocator, segment, config);

        stats.true_positives_sec += true_positives_sec;
        stats.total_positives_sec += true_positives_sec;
    }

    for (eval.reference_segments) |ref_segment| {
        if (ref_segment.duration() < config.ignore_shorter_than_sec) continue;

        const false_negative_sec = try calcFalseNegativeSec(eval.allocator, ref_segment, config);
        stats.false_negatives_sec += false_negative_sec;
        stats.total_positives_sec += false_negative_sec;
    }

    stats.true_positive_rate = stats.true_positives_sec / stats.total_positives_sec;
    stats.false_negative_rate = stats.false_negatives_sec / stats.total_positives_sec;
    stats.false_discovery_rate = stats.false_positives_sec / (stats.false_positives_sec + stats.true_positives_sec);
    stats.precision = stats.true_positives_sec / (stats.true_positives_sec + stats.false_positives_sec);

    stats.f_score_beta = 0.7;
    stats.f_score = f_score(stats.f_score_beta, stats.precision, stats.true_positive_rate);
    stats.fm_index = fm_index(stats.precision, stats.true_positive_rate);

    return stats;
}

pub fn aggregate(stats: []SingleStats) AggregateStats {
    var agg = AggregateStats{};

    var sum_true_positive_rate: f32 = 0.0;
    var sum_false_negative_rate: f32 = 0.0;
    var sum_false_discovery_rate: f32 = 0.0;
    var sum_precision: f32 = 0.0;

    for (stats) |s| {
        agg.total_positives_sec += s.total_positives_sec;
        agg.true_positives_sec += s.true_positives_sec;
        agg.false_positives_sec += s.false_positives_sec;
        agg.false_negatives_sec += s.false_negatives_sec;

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

    agg.true_positive_rate.overall = agg.true_positives_sec / agg.total_positives_sec;
    agg.false_negative_rate.overall = agg.false_negatives_sec / agg.total_positives_sec;
    agg.false_discovery_rate.overall = agg.false_positives_sec / (agg.false_positives_sec + agg.true_positives_sec);
    agg.precision.overall = agg.true_positives_sec / (agg.true_positives_sec + agg.false_positives_sec);

    agg.true_positive_rate.avg = sum_true_positive_rate / n_stats_f;
    agg.false_negative_rate.avg = sum_false_negative_rate / n_stats_f;
    agg.false_discovery_rate.avg = sum_false_discovery_rate / n_stats_f;
    agg.precision.avg = sum_precision / n_stats_f;

    agg.f_score_beta = 0.7;
    agg.f_score = f_score(agg.f_score_beta, agg.precision.overall, agg.true_positive_rate.overall);
    agg.fm_index = fm_index(agg.precision.overall, agg.true_positive_rate.overall);

    return agg;
}

// F_[beta] = (1 + beta^2) * (PPV * TPR) / (beta^2 * PPV + TPR)
pub fn f_score(beta: f32, precision: f32, recall: f32) f32 {
    return (1 + pow(f32, beta, 2)) * (precision * recall) / (pow(f32, beta, 2) * precision + recall);
}

/// Fowlkes–Mallows index = sqrt(TPR * PPV)
pub fn fm_index(precision: f32, recall: f32) f32 {
    return math.sqrt(precision * recall);
}

/// Extrude matched reference segments by a set duration and bridge short gaps
/// between them to obtain a more representative reference segment for comparison.
///
/// For example, a VAD segment that starts 2 seconds too early and ends 2
/// seconds too late (compared to the original reference segment) doesn't
/// have any performance penalty when fed to the speech recognition engine
/// so we don't penalize it as a false positive.
pub fn calcFalsePositiveSec(
    alloc: Allocator,
    vad_segment: SpeechSegment,
    config: StatConfig,
) !f32 {
    if (vad_segment.side != .vad) return error.InvalidSegmentSide;

    const extruded_ref_matches = try extrudeSegments(alloc, vad_segment.opposite_segments.?, config);
    defer alloc.free(extruded_ref_matches);

    const extruded_overlap = calcOverlapMany(vad_segment, extruded_ref_matches);
    return vad_segment.duration() - extruded_overlap;
}

pub fn calcTruePositiveSec(
    alloc: Allocator,
    vad_segment: SpeechSegment,
    config: StatConfig,
) !f32 {
    if (vad_segment.side != .vad) return error.InvalidSegmentSide;

    const fp = try calcFalsePositiveSec(alloc, vad_segment, config);
    return vad_segment.duration() - fp;
}

pub fn calcFalseNegativeSec(
    alloc: Allocator,
    ref_segment: SpeechSegment,
    config: StatConfig,
) !f32 {
    if (ref_segment.side != .ref) return error.InvalidSegmentSide;

    _ = config;
    _ = alloc;
    const overlap = calcOverlapWithMatches(ref_segment);
    return ref_segment.duration() - overlap;
}

pub fn extrudeSegments(
    allocator: Allocator,
    segments: []const *SpeechSegment,
    config: StatConfig,
) ![]SpeechSegment {
    var cloned: []SpeechSegment = try cloneSegments(allocator, segments);

    if (cloned.len == 0) {
        return cloned;
    }

    var first = &cloned[0];
    var last = &cloned[cloned.len - 1];

    first.from_sec -= config.extrude_start;
    last.to_sec += config.extrude_end;

    for (0..cloned.len - 1) |i| {
        var current = &cloned[i];
        var next = &cloned[i + 1];

        if (next.from_sec - current.to_sec <= config.fill_gaps) {
            current.to_sec = next.from_sec;
        }
    }

    return cloned;
}

pub fn cloneSegments(
    allocator: Allocator,
    segments: []const *SpeechSegment,
) ![]SpeechSegment {
    var cloned = try allocator.alloc(SpeechSegment, segments.len);

    for (segments, 0..) |s, i| {
        cloned[i] = s.*;
        cloned[i].next = null;
        cloned[i].prev = null;
        cloned[i].opposite_segments = null;
    }

    return cloned;
}

pub fn calcOverlapWithMatches(segment: SpeechSegment) f32 {
    var overlap: f32 = 0.0;
    for (segment.opposite_segments.?) |o| overlap += @max(0.0, segment.overlapWith(o.*));
    return overlap;
}

pub fn calcOverlapMany(segment: SpeechSegment, others: []const SpeechSegment) f32 {
    var overlap: f32 = 0.0;
    for (others) |o| overlap += @max(0.0, segment.overlapWith(o));
    return overlap;
}

test "calcFalsePositiveSec #1" {
    var ref_segments: []const SpeechSegment = &.{
        SpeechSegment{
            .side = .ref,
            .id = 1,
            .from_sec = 2,
            .to_sec = 3,
        },
        SpeechSegment{
            .side = .ref,
            .id = 2,
            .from_sec = 4,
            .to_sec = 5,
        },
    };
    var ref_segments_ptrs: []const *SpeechSegment = &.{
        @constCast(&ref_segments[0]),
        @constCast(&ref_segments[1]),
    };

    var vad_segment = SpeechSegment{
        .side = .vad,
        .id = 1,
        .from_sec = 1,
        .to_sec = 6,
        .opposite_segments = @constCast(ref_segments_ptrs),
    };

    var config = StatConfig{
        .extrude_start = 2,
        .extrude_end = 2,
        .fill_gaps = 2,
    };

    const fp_sec = try calcFalsePositiveSec(std.testing.allocator, vad_segment, config);
    try std.testing.expectApproxEqAbs(fp_sec, 0, 0.001);
}

test "calcFalsePositiveSec #2" {
    var ref_segments: []const SpeechSegment = &.{
        SpeechSegment{
            .side = .ref,
            .id = 1,
            .from_sec = 2,
            .to_sec = 3,
        },
        SpeechSegment{
            .side = .ref,
            .id = 2,
            .from_sec = 4,
            .to_sec = 5,
        },
    };
    var ref_segments_ptrs: []const *SpeechSegment = &.{
        @constCast(&ref_segments[0]),
        @constCast(&ref_segments[1]),
    };

    var vad_segment = SpeechSegment{
        .side = .vad,
        .id = 1,
        .from_sec = 1,
        .to_sec = 10,
        .opposite_segments = @constCast(ref_segments_ptrs),
    };

    var config = StatConfig{
        .extrude_start = 2,
        .extrude_end = 2,
        .fill_gaps = 2,
    };

    const fp_sec = try calcFalsePositiveSec(std.testing.allocator, vad_segment, config);
    try std.testing.expectApproxEqAbs(fp_sec, 3, 0.001);
}

const std = @import("std");
const log = std.log.scoped(.data_logger);
const zuckdb = @import("zuckdb");
const AudioPipeline = @import("./AudioPipeline.zig");
const BufferedFFT = @import("./AudioPipeline/BufferedFFT.zig");
const BufferedStep = @import("./AudioPipeline/BufferedStep.zig");
const Evaluator = @import("./Evaluator.zig");
const audio_utils = @import("./audio_utils.zig");
const duckdb = zuckdb.c;

const DataLogger = @This();

pub const Options = struct {
    read_only: bool = false,
    pool_size: usize = 50,
};

allocator: std.mem.Allocator,
db: zuckdb.DB,
pool: *zuckdb.Pool,

/// Same database should only be opened once per process since `database_open` isn't thread-safe,
/// especially when a new database is created (some thread complain about an empty/corrupt file).
pub fn open(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: Options,
) !*DataLogger {
    var self = try allocator.create(@This());
    errdefer allocator.destroy(self);

    self.allocator = allocator;

    var maybe_err: ?[]u8 = null;
    errdefer {
        if (maybe_err) |err| {
            log.err("DuckDB init error: {s}", .{err});
            allocator.free(err);
        }
    }
    self.db = try zuckdb.DB.initWithErr(
        allocator,
        path,
        .{
            .access_mode = if (opts.read_only) .read_only else .read_write,
        },
        &maybe_err,
    );
    errdefer self.db.deinit();

    self.pool = try self.db.pool(.{ .size = opts.pool_size });
    return self;
}

pub fn deinit(self: *DataLogger) void {
    self.pool.deinit();
    self.allocator.destroy(self);
}

pub fn createTables(self: *DataLogger) !void {
    var conn = try self.pool.acquire();
    defer conn.release();

    errdefer printError(conn);
    _ = try conn.exec(schema, .{});
}

pub fn acquireVADDataLogger(self: *DataLogger) !*VADDataLogger {
    return VADDataLogger.init(self);
}

fn printError(zuck_conn: *zuckdb.Conn) void {
    if (zuck_conn.err) |err| {
        log.err("DataLogger query error: {s}", .{err});
    } else {
        log.err("DataLogger query error: <Missing error when checked>", .{});
    }
}

pub const StreamInfo = struct {
    allocator: ?std.mem.Allocator = null,
    id: ?i32 = null,
    name: []const u8,
    sample_rate: usize,

    pub fn deinit(self: *StreamInfo) void {
        if (self.allocator) |alloc| {
            alloc.free(self.name);
        }
    }
};

pub const RefSegment = struct {
    id: ?i32 = null,
    from_sample: u64,
    to_sample: u64,
};

const VADDataInput = struct {
    fft: *const BufferedFFT.FFTResult,
    output: *const BufferedStep.Result,
    silero_vad: f32,
};

pub const VADData = struct {
    sample_number: u64,
    volume_rms: f32,
    channel_vol_ratio: ?f32,
    silero_vad: f32,
    fft_band_100_300: f32,
};

pub const VADDataLogger = struct {
    allocator: std.mem.Allocator,
    conn: *zuckdb.Conn,
    stream_info_id: ?i32 = null,
    stream_info: ?StreamInfo = null,
    vad_appender: zuckdb.Appender,
    data_logger_db: *DataLogger,

    pub fn init(data_logger_db: *DataLogger) !*VADDataLogger {
        const allocator = data_logger_db.allocator;

        var conn = try data_logger_db.pool.acquire();
        errdefer conn.release();

        var self = try allocator.create(VADDataLogger);

        self.* = VADDataLogger{
            .allocator = allocator,
            .conn = conn,
            .vad_appender = undefined,
            .data_logger_db = data_logger_db,
        };

        self.vad_appender = try self.conn.appender(null, "vad_data");
        errdefer self.vad_appender.deinit();

        return self;
    }

    pub fn deinit(self: *VADDataLogger) void {
        self.vad_appender.flush() catch |err| {
            std.log.err("Failed to flush VADDataLogger appender: {any}", .{err});
        };

        self.vad_appender.deinit();
        self.conn.release();
        self.allocator.destroy(self);
    }

    pub fn initStreamInfo(self: *VADDataLogger, stream_info: StreamInfo) !void {
        if (stream_info.id != null) return error.IdAlreadyPresent;
        if (self.stream_info_id != null) return error.StreamInfoAlreadyInitialized;

        errdefer printError(self.conn);
        var rows = try self.conn.query(
            "INSERT INTO stream_info (name, sample_rate) VALUES (?, ?) RETURNING id",
            .{ stream_info.name, stream_info.sample_rate },
        );
        defer rows.deinit();

        const first_row = try rows.next();
        const id = first_row.?.get(i32, 0);

        self.stream_info_id = id;
        self.stream_info = stream_info;
    }

    pub fn logVAD(self: *VADDataLogger, data: VADDataInput) !void {
        if (self.stream_info_id == null) return error.MissingStreamInfoId;

        const appender = &self.vad_appender;

        errdefer {
            std.debug.panic("logVAD appender error: {s}", .{appender.err orelse "<null>"});
        }
        const row = &.{
            self.stream_info_id.?,
            data.output.segment.index,
            data.output.segment.length(),
            data.output.metadata.volume_rms,
            data.output.metadata.volume_ratio,
            data.output.metadata.silero_vad,
            try data.fft.averageVolumeInBand(100, 300, false),
            try data.fft.averageVolumeInBand(300, 500, false),
            try data.fft.averageVolumeInBand(500, 700, false),
            try data.fft.averageVolumeInBand(700, 900, false),
        };
        try appender.appendRow(row);
    }

    pub fn insertRefSegments(self: *VADDataLogger, ref_segments: []const Evaluator.SpeechSegment) !void {
        if (self.stream_info_id == null) return error.MissingStreamInfoId;

        try self.conn.begin();
        errdefer self.conn.rollback() catch unreachable;

        for (ref_segments) |segment| {
            errdefer printError(self.conn);

            const from_sample = audio_utils.secondsToSamples(segment.from_sec, self.stream_info.?.sample_rate);
            const to_sample = audio_utils.secondsToSamples(segment.to_sec, self.stream_info.?.sample_rate);

            _ = try self.conn.exec(
                "INSERT INTO reference_segments (stream_info_id, from_sample, to_sample) VALUES (?, ?, ?)",
                .{
                    self.stream_info_id.?,
                    from_sample,
                    to_sample,
                },
            );
        }

        try self.conn.commit();
    }

    pub fn insertDetectedSegments(self: *VADDataLogger, ref_segments: []const AudioPipeline.SpeechSegment) !void {
        if (self.stream_info_id == null) return error.MissingStreamInfoId;

        try self.conn.begin();
        errdefer self.conn.rollback() catch unreachable;

        for (ref_segments) |segment| {
            errdefer printError(self.conn);

            _ = try self.conn.exec(
                "INSERT INTO detected_segments (stream_info_id, from_sample, to_sample) VALUES (?, ?, ?)",
                .{
                    self.stream_info_id.?,
                    segment.detected_sample_from,
                    segment.detected_sample_to,
                },
            );
        }
        try self.conn.commit();
    }

    /// Returns up to `results.len` results with ID > `after_id`, as a subslice of the original slice.
    pub fn findStreamInfo(
        self: *VADDataLogger,
        allocator: std.mem.Allocator,
        results: []StreamInfo,
        after_id: ?i32,
    ) ![]StreamInfo {
        errdefer printError(self.conn);
        var rows = try self.conn.query(
            "SELECT CAST(id AS INTEGER), name, CAST(sample_rate AS UINTEGER) FROM stream_info WHERE id > $1 ORDER BY id ASC LIMIT $2",
            .{ after_id orelse -1, results.len },
        );
        defer rows.deinit();

        var i: u32 = 0;
        while (try rows.next()) |row| : (i += 1) {
            const stream_info = &results[i];

            stream_info.* = .{
                .id = row.get(i32, 0),
                .name = row.get([]const u8, 1),
                .sample_rate = row.get(u32, 2),
            };

            stream_info.allocator = allocator;
            stream_info.name = try allocator.dupe(u8, stream_info.name);
        }

        return results[0..i];
    }

    /// Returns up to `results.len` results with `id` > `after_sample` as a subslice of the original slice.
    pub fn findRefSegments(
        self: *VADDataLogger,
        stream_info_id: i32,
        results: []RefSegment,
        after_id: ?i32,
    ) ![]RefSegment {
        const id_filter: i32 = after_id orelse -1;

        errdefer printError(self.conn);
        var rows = try self.conn.query(
            "SELECT CAST(id AS INTEGER), CAST(from_sample AS UBIGINT), CAST(to_sample AS UBIGINT) FROM reference_segments WHERE stream_info_id = $1 AND id > $2 ORDER BY id ASC LIMIT $3",
            .{
                stream_info_id,
                id_filter,
                results.len,
            },
        );
        defer rows.deinit();

        var i: u32 = 0;
        while (try rows.next()) |row| : (i += 1) {
            const vad_data = &results[i];

            vad_data.* = RefSegment{
                .id = row.get(i32, 0),
                .from_sample = row.get(u64, 1),
                .to_sample = row.get(u64, 2),
            };
        }

        return results[0..i];
    }

    /// Returns up to `results.len` results with `sample_number` > `after_sample` as a subslice of the original slice.
    pub fn findVADData(
        self: *VADDataLogger,
        stream_info_id: i32,
        results: []VADData,
        after_sample: ?u64,
    ) ![]VADData {
        const sample_num_filter: i64 = if (after_sample) |x| @intCast(x) else -1;

        errdefer printError(self.conn);
        var rows = try self.conn.query(
            \\SELECT CAST(sample_number AS UBIGINT), 
            \\      volume_rms,
            \\      channel_vol_ratio,
            \\      silero_vad,
            \\      fft_band_100_300
            \\FROM vad_data
            \\WHERE stream_info_id = $1 AND sample_number > $2
            \\ORDER BY sample_number ASC LIMIT $3
        ,
            .{
                stream_info_id,
                sample_num_filter,
                results.len,
            },
        );
        defer rows.deinit();

        var i: u32 = 0;
        while (try rows.next()) |row| : (i += 1) {
            const vad_data = &results[i];

            vad_data.* = VADData{
                .sample_number = row.get(u64, 0),
                .volume_rms = row.get(f32, 1),
                .channel_vol_ratio = row.get(?f32, 2),
                .silero_vad = row.get(f32, 3),
                .fft_band_100_300 = row.get(f32, 4),
            };
        }

        return results[0..i];
    }
};

const schema =
    \\CREATE SEQUENCE IF NOT EXISTS 'stream_info_id_seq';
    \\CREATE TABLE IF NOT EXISTS stream_info (
    \\  id INTEGER PRIMARY KEY DEFAULT nextval('stream_info_id_seq'),
    \\  name VARCHAR NOT NULL,
    \\  sample_rate INTEGER NOT NULL
    \\);
    \\
    \\
    \\CREATE TABLE IF NOT EXISTS vad_data (
    \\  stream_info_id INTEGER NOT NULL,
    \\  sample_number UBIGINT NOT NULL,
    \\  length UINTEGER NOT NULL,
    \\  volume_rms FLOAT4 NOT NULL,
    \\  channel_vol_ratio FLOAT4,
    \\  silero_vad FLOAT4 NOT NULL,
    \\  fft_band_100_300 FLOAT4 NOT NULL,
    \\  fft_band_300_500 FLOAT4 NOT NULL,
    \\  fft_band_500_700 FLOAT4 NOT NULL,
    \\  fft_band_700_900 FLOAT4 NOT NULL
    \\);
    \\
    \\CREATE SEQUENCE IF NOT EXISTS 'reference_segments_id_seq';
    \\CREATE TABLE IF NOT EXISTS reference_segments (
    \\  id INTEGER PRIMARY KEY DEFAULT nextval('reference_segments_id_seq'),
    \\  stream_info_id INTEGER NOT NULL,
    \\  from_sample UBIGINT NOT NULL,
    \\  to_sample UBIGINT NOT NULL
    \\);
    \\
    \\CREATE SEQUENCE IF NOT EXISTS 'detected_segments_id_seq';
    \\CREATE TABLE IF NOT EXISTS detected_segments (
    \\  id INTEGER PRIMARY KEY DEFAULT nextval('detected_segments_id_seq'),
    \\  stream_info_id INTEGER NOT NULL,
    \\  from_sample INTEGER NOT NULL,
    \\  to_sample INTEGER NOT NULL
    \\);
    \\
    \\
    \\-- information about where each stream's speech begins and ends (first sample of first speech and last sample of last speech)
    \\CREATE OR REPLACE VIEW ref_speech_limits AS
    \\  SELECT stream_info_id, min(from_sample) AS from_sample, max(to_sample) AS to_sample
    \\  FROM reference_segments
    \\  GROUP BY stream_info_id
    \\;
    \\
    \\-- marks regions of VAD data as ambiguous due to inaccuracies in manual labelling (which are typically slightly wide than speech itself)
    \\--   + region from 0.25s before labelled start to 1.00s after labelled start 
    \\--   + region from 1.00s before labelled end   to 0.25s after labelled end
    \\CREATE OR REPLACE VIEW ambiguous_regions AS (
    \\  WITH ref_segments_joined AS (
    \\    SELECT rs.*, si.sample_rate
    \\    FROM reference_segments rs
    \\    INNER JOIN stream_info si ON rs.stream_info_id = si.id
    \\  )
    \\  (
    \\    SELECT stream_info_id,
    \\           CAST(GREATEST(0, from_sample - 0.1 * sample_rate) AS INTEGER) AS from_sample,
    \\           CAST((from_sample + 0.4 * sample_rate) AS INTEGER) AS to_sample,
    \\           'start' AS side
    \\    FROM ref_segments_joined rsj
    \\  )
    \\  UNION ALL
    \\  (
    \\    SELECT stream_info_id,
    \\           CAST(GREATEST(0, to_sample - 0.4 * sample_rate) AS INTEGER) AS from_sample,
    \\           CAST((to_sample + 0.1 * sample_rate) AS INTEGER) AS to_sample,
    \\           'end' AS side
    \\    FROM ref_segments_joined rsj
    \\  )
    \\);
    \\
    \\-- vad_data with each frame labelled as `is_ref_speech` and `is_detected_speech`, 'is_ambiguous'
    \\CREATE OR REPLACE VIEW labelled_vad_data AS
    \\  SELECT DISTINCT vd.*,
    \\          rs.id IS NOT NULL AS is_ref_speech,
    \\          ds.id IS NOT NULL AS is_detected_speech,
    \\          rsl.from_sample IS NOT NULL AS is_within_limits,
    \\          ar.from_sample IS NOT NULL AS is_ambiguous
    \\  FROM vad_data vd
    \\  LEFT JOIN reference_segments rs ON (rs.stream_info_id = vd.stream_info_id AND (vd.sample_number BETWEEN rs.from_sample AND rs.to_sample))
    \\  LEFT JOIN detected_segments ds ON (ds.stream_info_id = vd.stream_info_id AND (vd.sample_number BETWEEN ds.from_sample AND ds.to_sample))
    \\  LEFT JOIN ref_speech_limits rsl ON (rsl.stream_info_id = vd.stream_info_id AND (vd.sample_number BETWEEN rsl.from_sample AND rsl.to_sample))
    \\  LEFT JOIN ambiguous_regions ar ON (ar.stream_info_id = vd.stream_info_id AND (vd.sample_number BETWEEN ar.from_sample AND ar.to_sample))
    \\;
    \\
    \\-- creates a matrix that aggregates `vad_data` metrics for each combination of (is_detected, is_reference, is_ambiguous) labels
    \\-- it ignores data before first speech segment and after last speech segment (using `ref_speech_limits` view)
    \\CREATE OR REPLACE VIEW vad_data_matrix AS (
    \\  SELECT si.id AS si_id, si.name,
    \\          is_ref_speech, is_detected_speech, is_ambiguous, is_within_limits,
    \\          SUM(vd.length) AS length,
    \\          SUM(vd.length) / ANY_VALUE(si.sample_rate) AS length_sec,
    \\          MEDIAN(silero_vad) AS silero_vad,
    \\          MEDIAN(volume_rms) AS volume_rms,
    \\          MEDIAN(channel_vol_ratio) AS channel_vol_ratio,
    \\          MEDIAN(fft_band_100_300) AS fft_band_100_300,
    \\          MEDIAN(fft_band_300_500) AS fft_band_300_500,
    \\          MEDIAN(fft_band_500_700) AS fft_band_500_700,
    \\          MEDIAN(fft_band_700_900) AS fft_band_700_900,
    \\  FROM labelled_vad_data vd
    \\  INNER JOIN stream_info si on si.id = vd.stream_info_id
    \\  GROUP BY si.id, si.name, is_ref_speech, is_detected_speech, is_ambiguous, is_within_limits
    \\);
    \\
    \\CREATE OR REPLACE VIEW vad_data_aggregated AS (
    \\  WITH vdm AS (SELECT * FROM vad_data_matrix WHERE is_within_limits AND NOT is_ambiguous),
    \\       vdm_pivot AS (
    \\         PIVOT vdm
    \\         ON is_ref_speech IN (true, false), is_detected_speech IN (true, false)
    \\         USING SUM(length) as length_sum,
    \\               SUM(silero_vad / length) as silero_vad,
    \\               SUM(volume_rms / length) AS volume_rms,
    \\               MEDIAN(channel_vol_ratio / length) AS channel_vol_ratio,
    \\               SUM((fft_band_100_300 + fft_band_300_500) / 2 / length) as fft_bands
    \\         GROUP BY si_id
    \\       )
    \\  SELECT si.id, si.name,
    \\         true_true_silero_vad / ((false_true_silero_vad * false_true_length_sum + false_false_silero_vad * false_false_length_sum)/(false_true_length_sum + false_false_length_sum)) AS tp_silero_vad,
    \\         false_true_silero_vad / false_false_silero_vad AS fp_silero_vad,
    \\         true_false_silero_vad / ((false_true_silero_vad * false_true_length_sum + false_false_silero_vad * false_false_length_sum)/(false_true_length_sum + false_false_length_sum)) AS fn_silero_vad,
    \\
    \\         true_true_volume_rms / ((false_true_volume_rms * false_true_length_sum + false_false_volume_rms * false_false_length_sum)/(false_true_length_sum + false_false_length_sum)) AS tp_volume_rms,
    \\         false_true_volume_rms / false_false_volume_rms AS fp_volume_rms,
    \\         true_false_volume_rms / ((false_true_volume_rms * false_true_length_sum + false_false_volume_rms * false_false_length_sum)/(false_true_length_sum + false_false_length_sum)) AS fn_volume_rms,
    \\
    \\         true_true_channel_vol_ratio AS tp_channel_vol_ratio,
    \\         false_true_channel_vol_ratio AS fp_channel_vol_ratio,
    \\         true_false_channel_vol_ratio AS fn_channel_vol_ratio,
    \\
    \\         true_true_fft_bands / ((false_true_fft_bands * false_true_length_sum + false_false_fft_bands * false_false_length_sum)/(false_true_length_sum + false_false_length_sum)) AS tp_fft_bands,
    \\         false_true_fft_bands / false_false_fft_bands AS fp_fft_bands,
    \\         true_false_fft_bands / ((false_true_fft_bands * false_true_length_sum + false_false_fft_bands * false_false_length_sum)/(false_true_length_sum + false_false_length_sum)) AS fn_fft_bands,
    \\  FROM vdm_pivot
    \\  INNER JOIN stream_info si ON si.id = vdm_pivot.si_id
    \\);
    \\
    \\
    \\-- vad_data joined with detected segments
    \\CREATE OR REPLACE VIEW detected_segment_vad_data AS
    \\  SELECT ds.id as ds_id, ds.from_sample, ds.to_sample, vd.*
    \\  FROM detected_segments ds
    \\  INNER JOIN vad_data vd ON
    \\      (vd.stream_info_id = ds.stream_info_id AND
    \\          (vd.sample_number BETWEEN ds.from_sample AND ds.to_sample)
    \\      )
    \\;
    \\
    \\-- vad_data joined with reference segments
    \\CREATE OR REPLACE VIEW ref_segment_vad_data AS
    \\  SELECT rs.id as rs_id, rs.from_sample, rs.to_sample, vd.*
    \\  FROM reference_segments rs
    \\  INNER JOIN vad_data vd ON
    \\      (vd.stream_info_id = rs.stream_info_id AND
    \\          (vd.sample_number BETWEEN rs.from_sample AND rs.to_sample)
    \\      )
    \\;
    \\
    \\-- all segments overlapped with each another (per-stream), this doesn't take into account the fact that 
    \\-- one reference segment could correspond to multiple detected segments or vice versa, 
    \\-- this means that early/late start/end calculations won't make sense in those cases unless they're processed further.
    \\CREATE OR REPLACE VIEW overlapped_segments AS
    \\  SELECT ds.stream_info_id AS si_id,
    \\          ds.from_sample AS det_from,
    \\          ds.to_sample AS det_to,
    \\          rs.from_sample AS ref_from,
    \\          rs.to_sample AS ref_to,
    \\          GREATEST(0, (LEAST(ds.to_sample, rs.to_sample) - GREATEST(ds.from_sample, rs.from_sample))  ) AS overlap,
    \\          CASE WHEN overlap = 0 THEN NULL ELSE GREATEST(0, ds.from_sample - rs.from_sample) END AS late_start,
    \\          CASE WHEN overlap = 0 THEN NULL ELSE GREATEST(0, rs.from_sample - ds.from_sample) END AS early_start,
    \\          CASE WHEN overlap = 0 THEN NULL ELSE GREATEST(0, ds.to_sample - rs.to_sample) END AS late_end,
    \\          CASE WHEN overlap = 0 THEN NULL ELSE GREATEST(0, ds.from_sample - rs.from_sample) END AS early_end,
    \\          (overlap / si.sample_rate) AS overlap_sec,
    \\          (late_start / si.sample_rate) AS late_start_sec,
    \\          (early_start / si.sample_rate) AS early_start_sec,
    \\          (late_end / si.sample_rate) AS late_end_sec,
    \\          (early_end / si.sample_rate) AS early_end_sec,
    \\  FROM detected_segments ds
    \\  INNER JOIN stream_info si ON si.id = ds.stream_info_id
    \\  FULL OUTER JOIN reference_segments rs ON (ds.stream_info_id = rs.stream_info_id)
    \\;
    \\
    \\-- detected segments that were incorrectly detected by VAD (no overlap with any reference segment)
    \\CREATE OR REPLACE VIEW false_positives AS
    \\  SELECT si.id AS si_id,
    \\      os.det_from AS from,
    \\      os.det_to AS to,
    \\      (os.det_to - os.det_from) AS duration,
    \\      (os.det_from / si.sample_rate) AS det_from_sec,
    \\      (os.det_to / si.sample_rate) AS det_to_sec,
    \\      (duration / si.sample_rate) AS duration_sec
    \\  FROM overlapped_segments os
    \\  INNER JOIN stream_info si ON si.id = os.si_id
    \\  GROUP BY (si.id, si.sample_rate, os.det_from, os.det_to)
    \\  HAVING MAX(overlap) = 0
    \\;
    \\
    \\-- reference segments that were completely missed by VAD (no overlap with any detected segments)
    \\CREATE OR REPLACE VIEW false_negatives AS
    \\  SELECT si.id AS si_id,
    \\      os.ref_from as from,
    \\      os.ref_to as to,
    \\      (os.ref_to - os.ref_from) AS duration,
    \\      (os.ref_from / si.sample_rate) AS ref_from_sec,
    \\      (os.ref_to / si.sample_rate) AS ref_to_sec,
    \\      (duration / si.sample_rate) AS duration_sec
    \\  FROM overlapped_segments os
    \\  INNER JOIN stream_info si ON si.id = os.si_id
    \\  GROUP BY (si.id, si.sample_rate, os.ref_from, os.ref_to)
    \\  HAVING MAX(overlap) = 0
    \\;
    \\
;

// Alternative labelled_vad_data implementations (~5-10x slower)
//
// \\-- vad_data with each frame labelled as `is_ref_speech` and `is_detected_speech`, 'is_ambiguous'
// \\CREATE OR REPLACE VIEW labelled_vad_data AS
// \\  SELECT vd.*,
// \\          EXISTS (SELECT 1 FROM reference_segments rs WHERE rs.stream_info_id = vd.stream_info_id AND vd.sample_number BETWEEN rs.from_sample AND rs.to_sample) AS is_ref_speech,
// \\          EXISTS (SELECT 1 FROM detected_segments ds WHERE ds.stream_info_id = vd.stream_info_id AND vd.sample_number BETWEEN ds.from_sample AND ds.to_sample) AS is_detected_speech,
// \\          EXISTS (SELECT 1 FROM ambiguous_regions ar WHERE ar.stream_info_id = vd.stream_info_id AND vd.sample_number BETWEEN ar.from_sample AND ar.to_sample) AS is_ambiguous,
// \\          EXISTS (SELECT 1 FROM ref_speech_limits rsl WHERE rsl.stream_info_id = vd.stream_info_id AND vd.sample_number BETWEEN rsl.from_sample AND rsl.to_sample) AS is_within_limits
// \\  FROM vad_data vd
// \\;
// \\
// \\-- vad_data with each frame labelled as `is_ref_speech` and `is_detected_speech`, 'is_ambiguous'
// \\CREATE OR REPLACE VIEW labelled_vad_data AS
// \\  SELECT vd.*
// \\  FROM vad_data vd,
// \\       LATERAL (SELECT COUNT(*) > 0 AS is_ref_speech FROM reference_segments rs WHERE rs.stream_info_id = vd.stream_info_id AND vd.sample_number BETWEEN rs.from_sample AND rs.to_sample),
// \\       LATERAL (SELECT COUNT(*) > 0 AS is_detected_speech FROM detected_segments ds WHERE ds.stream_info_id = vd.stream_info_id AND vd.sample_number BETWEEN ds.from_sample AND ds.to_sample),
// \\       LATERAL (SELECT COUNT(*) > 0 AS is_ambiguous FROM ambiguous_regions ar WHERE ar.stream_info_id = vd.stream_info_id AND vd.sample_number BETWEEN ar.from_sample AND ar.to_sample),
// \\       LATERAL (SELECT COUNT(*) > 0 AS is_within_limits FROM ref_speech_limits rsl WHERE rsl.stream_info_id = vd.stream_info_id AND vd.sample_number BETWEEN rsl.from_sample AND rsl.to_sample)
// \\;

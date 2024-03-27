const std = @import("std");
const log = std.log.scoped(.data_logger);
const zuckdb = @import("zuckdb");
const BufferedFFT = @import("./AudioPipeline/BufferedFFT.zig");
const BufferedStep = @import("./AudioPipeline/BufferedStep.zig");
const Evaluator = @import("./Evaluator.zig");
const audio_utils = @import("./audio_utils.zig");
const duckdb = zuckdb.c;

const DataLoggerDB = @This();

allocator: std.mem.Allocator,
db: zuckdb.DB,

/// Same database should only be opened once per process since `database_open` isn't thread-safe.
pub fn open(
    allocator: std.mem.Allocator,
    path: []const u8,
) !DataLoggerDB {
    var maybe_err: ?[]u8 = null;
    errdefer {
        if (maybe_err) |err| {
            log.err("DuckDB init error: {s}", .{err});
            allocator.free(err);
        }
    }
    const db = try zuckdb.DB.initWithErr(allocator, path, .{}, &maybe_err);
    errdefer db.deinit();

    return DataLoggerDB{
        .allocator = allocator,
        .db = db,
    };
}

pub fn createTables(self: *DataLoggerDB) !void {
    const query =
        \\CREATE TABLE IF NOT EXISTS vad_data (
        \\  stream_info_id UINTEGER NOT NULL,
        \\  sample_number UINTEGER NOT NULL,
        \\  volume_rms FLOAT4 NOT NULL,
        \\  channel_vol_ratio FLOAT4,
        \\  silero_vad FLOAT4 NOT NULL,
        \\  fft_band_100_300 FLOAT4 NOT NULL,
        \\  fft_band_300_500 FLOAT4 NOT NULL,
        \\  fft_band_500_700 FLOAT4 NOT NULL,
        \\  fft_band_700_900 FLOAT4 NOT NULL
        \\);
        \\
        \\CREATE SEQUENCE 'stream_info_id_seq';
        \\
        \\CREATE TABLE IF NOT EXISTS stream_info (
        \\  id UINTEGER PRIMARY KEY DEFAULT nextval('stream_info_id_seq'),
        \\  name VARCHAR NOT NULL,
        \\  sample_rate UINTEGER NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS reference_segments (
        \\  stream_info_id UINTEGER NOT NULL,
        \\  from_sample UINTEGER NOT NULL,
        \\  to_sample UINTEGER NOT NULL
        \\);
    ;

    var conn = try self.db.conn();
    defer conn.deinit();

    errdefer printError(conn);
    _ = try conn.exec(query, .{});
}

pub fn deinit(self: *DataLoggerDB) void {
    self.db.deinit();
}

pub fn connect(self: *const DataLoggerDB, stream_info: Conn.StreamInfoInit) !*Conn {
    const conn = try Conn.init(self, stream_info);
    return conn;
}

fn printError(zuck_conn: zuckdb.Conn) void {
    if (zuck_conn.err) |err| {
        log.err("DataLogger query error: {s}", .{err});
    } else {
        log.err("DataLogger query error: <Missing error when checked>", .{});
    }
}

const VADData = struct {
    fft: *const BufferedFFT.FFTResult,
    output: *const BufferedStep.Result,
    silero_vad: f32,
};

pub const Conn = struct {
    allocator: std.mem.Allocator,
    conn: zuckdb.Conn,
    stream_info_id: ?u32 = null,
    stream_info: ?StreamInfoInit = null,
    vad_appender: duckdb.duckdb_appender,

    const StreamInfoInit = struct {
        name: []const u8,
        sample_rate: usize,
    };

    pub fn init(data_logger_db: *const DataLoggerDB, stream_info: StreamInfoInit) !*Conn {
        const allocator = data_logger_db.allocator;

        var self = try allocator.create(Conn);

        self.* = Conn{
            .allocator = allocator,
            .conn = try data_logger_db.db.conn(),
            .vad_appender = null,
        };

        const appender_result = duckdb.duckdb_appender_create(self.conn.conn.*, null, "vad_data", &self.vad_appender);
        if (appender_result == duckdb.DuckDBError) return error.CreateAppenderError;

        try self.initStreamInfo(stream_info);
        return self;
    }

    pub fn deinit(self: *Conn) void {
        if (self.vad_appender != null) {
            const code = duckdb.duckdb_appender_destroy(&self.vad_appender);
            if (code == duckdb.DuckDBError) unreachable;
        }
        self.conn.deinit();
        self.allocator.destroy(self);
    }

    fn initStreamInfo(self: *Conn, stream_info: StreamInfoInit) !void {
        if (self.stream_info_id != null) return error.StreamInfoAlreadyInitialized;

        errdefer printError(self.conn);
        var rows = try self.conn.query(
            "INSERT INTO stream_info (name, sample_rate) VALUES (?, ?) RETURNING id",
            .{ stream_info.name, stream_info.sample_rate },
        );
        defer rows.deinit();

        const first_row = try rows.next();
        const id = first_row.?.get(u32, 0);

        self.stream_info_id = id;
        self.stream_info = stream_info;
    }

    pub fn begin(self: *Conn) !void {
        errdefer printError(self.conn);
        try self.conn.begin();
    }

    pub fn commit(self: *Conn) !void {
        errdefer printError(self.conn);
        try self.conn.commit();
    }

    pub fn logVAD(self: *Conn, data: VADData) !void {
        if (self.stream_info_id == null) return error.MissingStreamInfoId;

        const columns = .{
            self.stream_info_id.?,
            data.output.segment.index,
            data.output.metadata.volume_rms,
            data.output.metadata.volume_ratio,
            data.output.metadata.silero_vad,
            try data.fft.averageVolumeInBand(100, 300, false),
            try data.fft.averageVolumeInBand(300, 500, false),
            try data.fft.averageVolumeInBand(500, 700, false),
            try data.fft.averageVolumeInBand(700, 900, false),
        };

        _ = duckdb.duckdb_append_uint32(self.vad_appender, columns[0]);
        _ = duckdb.duckdb_append_uint64(self.vad_appender, columns[1]);
        _ = if (columns[2]) |val| duckdb.duckdb_append_float(self.vad_appender, val) else duckdb.duckdb_append_null(self.vad_appender);
        _ = if (columns[3]) |val| duckdb.duckdb_append_float(self.vad_appender, val) else duckdb.duckdb_append_null(self.vad_appender);
        _ = if (columns[4]) |val| duckdb.duckdb_append_float(self.vad_appender, val) else duckdb.duckdb_append_null(self.vad_appender);
        _ = duckdb.duckdb_append_float(self.vad_appender, columns[5]);
        _ = duckdb.duckdb_append_float(self.vad_appender, columns[6]);
        _ = duckdb.duckdb_append_float(self.vad_appender, columns[7]);
        _ = duckdb.duckdb_append_float(self.vad_appender, columns[8]);

        const result = duckdb.duckdb_appender_end_row(self.vad_appender);
        if (result == duckdb.DuckDBError) {
            const err = duckdb.duckdb_appender_error(self.vad_appender);
            std.debug.panic("Appender error: {s}", .{err});
        }
    }

    pub fn insertRefSegments(self: *Conn, ref_segments: []const Evaluator.SpeechSegment) !void {
        if (self.stream_info_id == null) return error.MissingStreamInfoId;

        for (ref_segments) |segment| {
            errdefer printError(self.conn);

            const from_sample = audio_utils.secondsToSampleNumber(segment.from_sec, self.stream_info.?.sample_rate);
            const to_sample = audio_utils.secondsToSampleNumber(segment.to_sec, self.stream_info.?.sample_rate);

            _ = try self.conn.exec(
                "INSERT INTO reference_segments (stream_info_id, from_sample, to_sample) VALUES (?, ?, ?)",
                .{
                    self.stream_info_id.?,
                    from_sample,
                    to_sample,
                },
            );
        }
    }
};

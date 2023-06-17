const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;
const json = std.json;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const AudioPipeline = @import("./AudioPipeline.zig");
const AudioBuffer = @import("./audio_utils/AudioBuffer.zig");
const uuid = @import("./uuid.zig");
const clap = @import("clap");

/// stdlib option overrides
pub const std_options = struct {
    pub const log_level = .info;
    pub const log_scope_levels = &.{
        .{
            .scope = .vad,
            .level = .info,
        },
    };
};

const log = std.log.scoped(.main);
const exit = std.os.exit;
const stdin = std.io.getStdIn();
const stderr = std.io.getStdErr();
const stdout = std.io.getStdOut();
const stdin_r = stdout.reader();
const stderr_w = stdout.writer();
const stdout_w = stdout.writer();

const CommandName = enum {
    segment,
    skip_segment,
};

const InCommandJSON = struct {
    name: CommandName,
    file_path: ?[]const u8 = null,
    playhead_timestamp_ms: ?u64 = null,
};

const OutRecordingJSON = struct {
    name: []const u8,
    file_path: []const u8,
    playhead_timestamp_ms: i64,
    duration_ms: u64,
};

const OutErrorJSON = struct {
    message: []const u8,
    fatal: bool,
};

const Config = struct {
    name: []const u8,
    out_dir: []const u8,
};

const ProcessLoopState = struct {
    allocator: Allocator,
    callback_arena: std.heap.ArenaAllocator,
    config: Config,
    pipeline: *AudioPipeline,
    correlated_sample_index: u64 = 0,
    correlated_timestamp_ms: u64 = 0,
    last_segment_length: u64 = 0,
};

const cli_params = clap.parseParamsComptime(
    \\-h, --help                Display this help and exit
    \\-o, --outdir <string>     Output directory
    \\-n, --name <string>       Name of this instance for logging
    \\
);

fn printHelp() !void {
    try clap.help(stderr_w, clap.Help, &cli_params, .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &cli_params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try printHelp();
        diag.report(stderr.writer(), err) catch {};
        exit(1);
    };
    defer res.deinit();

    const args = res.args;

    if (args.help == 1) {
        try printHelp();
        return;
    }

    if (args.name == null or args.outdir == null) {
        try printHelp();
        exit(1);
    }

    const name = args.name.?;
    const out_dir = args.outdir.?;

    // Ensure that output directory is writeable
    fs.Dir.access(fs.cwd(), out_dir, .{ .mode = .read_write }) catch |err| {
        const msg = try fmt.allocPrint(allocator, "Output directory {s} isn't writeable: {any}", .{ out_dir, err });
        reportError(allocator, msg, true);
        exit(2);
    };

    // Setup pipeline and callbacks
    const config = Config{
        .name = name,
        .out_dir = out_dir,
    };

    const pipeline_config = AudioPipeline.Config{
        .sample_rate = 48000,
        .n_channels = 2,
        .buffer_length = 48000 * 10,
    };

    var process_loop = ProcessLoopState{
        .allocator = allocator,
        .callback_arena = std.heap.ArenaAllocator.init(allocator),
        .config = config,
        .pipeline = undefined,
    };

    var pipeline = try AudioPipeline.init(
        allocator,
        pipeline_config,
        AudioPipeline.Callbacks{
            .ctx = &process_loop,
            .on_original_recording = &onRecording,
            .on_denoised_recording = null,
        },
    );
    errdefer pipeline.deinit();

    process_loop.pipeline = pipeline;

    try startProcessLoop(&process_loop);
}

pub fn startProcessLoop(process_loop: *ProcessLoopState) !void {
    const config = process_loop.config;
    log.info("{s}: Starting process loop. Out dir: {s}", .{ config.name, config.out_dir });

    var arena = std.heap.ArenaAllocator.init(process_loop.allocator);
    defer arena.deinit();
    var arena_alloc = arena.allocator();
    const megabyte = 1024 * 1024;

    while (true) {
        defer _ = arena.reset(.retain_capacity);

        const line = stdin_r.readUntilDelimiterAlloc(arena_alloc, '\n', megabyte) catch |err| {
            if (err == error.EndOfStream) {
                log.err("Standard input closed, exiting", .{});
                exit(0);
            }

            const msg = try fmt.allocPrint(arena_alloc, "Error reading from stdin: {any}", .{err});
            reportError(arena_alloc, msg, false);
            continue;
        };

        const parsed = json.parseFromSlice(InCommandJSON, arena_alloc, line, .{}) catch |err| {
            const msg = try fmt.allocPrint(arena_alloc, "Error parsing command JSON: {any}. Line: {s}", .{ err, line });
            reportError(arena_alloc, msg, false);
            continue;
        };

        try processCommand(arena_alloc, process_loop, parsed);
    }
}

fn processCommand(
    arena_alloc: Allocator,
    process_loop: *ProcessLoopState,
    command: InCommandJSON,
) !void {
    switch (command.name) {
        .segment => {
            try processSegment(arena_alloc, process_loop, command);
        },
        .skip_segment => {
            // Skip segments are used as a last resort, in case some of the audio data
            // is missing, we push silence to keep continuity of the sample index numbers
            try processSkipSegment(arena_alloc, process_loop);
        },
    }
}

fn processSegment(
    arena_alloc: Allocator,
    process_loop: *ProcessLoopState,
    command: InCommandJSON,
) !void {
    const n_pipeline_channels = process_loop.pipeline.config.n_channels;
    const pipeline_sample_rate = process_loop.pipeline.config.sample_rate;

    const file_path = command.file_path orelse {
        const msg = try fmt.allocPrint(arena_alloc, "Missing file_path in command: {any}", .{command});
        reportError(arena_alloc, msg, false);
        return;
    };

    const playhead_timestamp_ms = command.playhead_timestamp_ms orelse {
        const msg = try fmt.allocPrint(arena_alloc, "Missing playhead_timestamp_ms in command: {any}", .{command});
        reportError(arena_alloc, msg, false);
        return;
    };

    const buffer = AudioBuffer.loadFromFile(arena_alloc, file_path) catch |err| {
        const msg = try fmt.allocPrint(arena_alloc, "Error loading audio file: {any}. Command: {any}", .{ err, command });
        reportError(arena_alloc, msg, false);
        return;
    };

    if (buffer.n_channels != n_pipeline_channels) {
        const msg = try fmt.allocPrint(
            arena_alloc,
            "Audio file has {d} channels, but pipeline has {d} channels. Command: {any}",
            .{
                buffer.n_channels,
                n_pipeline_channels,
                command,
            },
        );
        reportError(arena_alloc, msg, false);

        // Assuming that this might be a transient error, we continue
        try processSkipSegment(arena_alloc, process_loop);
        return;
    }

    if (buffer.sample_rate != pipeline_sample_rate) {
        const msg = try fmt.allocPrint(arena_alloc, "Audio file has SR of {d}, but pipeline has SR of {d}. Command: {any}", .{
            buffer.sample_rate,
            pipeline_sample_rate,
            command,
        });
        reportError(arena_alloc, msg, true);

        // This is almost certainly not a transient error and should be fixed/enforced
        // by the caller
        return error.UnsupportedSampleRate;
    }

    const first_sample_idx = process_loop.pipeline.pushSamples(buffer.channel_pcm_buf) catch |err| {
        const msg = try fmt.allocPrint(arena_alloc, "Error pushing samples to pipeline: {any}. Command: {any}", .{ err, command });
        reportError(arena_alloc, msg, false);
        return;
    };

    process_loop.correlated_sample_index = first_sample_idx;
    process_loop.correlated_timestamp_ms = playhead_timestamp_ms;
    process_loop.last_segment_length = buffer.length;
}

fn processSkipSegment(
    arena_alloc: Allocator,
    process_loop: *ProcessLoopState,
) !void {
    const n_pipeline_channels = process_loop.pipeline.config.n_channels;

    var pcm = try arena_alloc.alloc(f32, process_loop.last_segment_length);
    var channels = try arena_alloc.alloc([]const f32, n_pipeline_channels);
    @memset(pcm, 0);
    for (0..n_pipeline_channels) |i| {
        channels[i] = pcm;
    }

    _ = process_loop.pipeline.pushSamples(channels) catch |err| {
        const msg = try fmt.allocPrint(arena_alloc, "Error pushing EMPTY samples to pipeline: {any}.", .{err});
        reportError(arena_alloc, msg, false);
        return;
    };
}

fn reportError(
    arena_alloc: Allocator,
    message: []const u8,
    fatal: bool,
) void {
    log.err("{s}", .{message});
    // Notify the parent process that a new recording is available via stdout
    const out = OutErrorJSON{
        .message = message,
        .fatal = fatal,
    };
    const out_json = std.json.stringifyAlloc(arena_alloc, out, .{}) catch unreachable;
    stdout_w.print("{s}\n", .{out_json}) catch unreachable;
}

fn onRecording(opaque_ctx: *anyopaque, audio_buffer: *const AudioBuffer) void {
    const process_loop: *ProcessLoopState = alignedPtrCast(opaque_ctx, ProcessLoopState);

    const arena_alloc = process_loop.callback_arena.allocator();
    defer _ = process_loop.callback_arena.reset(.retain_capacity);

    const out_dir = process_loop.config.out_dir;

    const filename = fmt.allocPrint(arena_alloc, "{}.wav", .{uuid.newV4()}) catch unreachable;
    const path = fs.path.resolve(arena_alloc, &.{ out_dir, filename }) catch |err| {
        const msg = fmt.allocPrint(
            arena_alloc,
            "Error resolving path: {any}. our_dir = {s}, filename = {s}",
            .{ err, out_dir, filename },
        ) catch unreachable;

        reportError(arena_alloc, msg, false);
        return;
    };

    log.info("{s}: Saving recording to {s}", .{ process_loop.config.name, path });
    audio_buffer.saveToFile(path, AudioBuffer.Format.wav) catch |err| {
        const msg = fmt.allocPrint(
            arena_alloc,
            "Error saving audio file: {any}. Path: {s}, AudioBuffer: {any}",
            .{ err, path, audio_buffer },
        ) catch unreachable;

        reportError(arena_alloc, msg, false);
        return;
    };

    const duration_ms = @floatToInt(u64, audio_buffer.duration_seconds * 1000);

    const samples_since_correlation =
        @intCast(i64, audio_buffer.global_start_frame_number.?) -
        @intCast(i64, process_loop.correlated_sample_index);

    const ms_since_correlation =
        1000 * @divTrunc(
        @intCast(i64, samples_since_correlation),
        @intCast(i64, audio_buffer.sample_rate),
    );

    const playhead_timestamp_ms =
        @intCast(i64, process_loop.correlated_timestamp_ms) +
        ms_since_correlation;

    // Notify the parent process that a new recording is available via stdout
    const out = OutRecordingJSON{
        .file_path = path,
        .name = process_loop.config.name,
        .playhead_timestamp_ms = playhead_timestamp_ms,
        .duration_ms = duration_ms,
    };
    const out_json = std.json.stringifyAlloc(arena_alloc, out, .{}) catch |err| {
        const msg = fmt.allocPrint(
            arena_alloc,
            "Error serializing output: {any}. Output: {any}",
            .{ err, out },
        ) catch unreachable;

        reportError(arena_alloc, msg, false);
        return;
    };

    stdout_w.print("{s}\n", .{out_json}) catch unreachable;
}

fn alignedPtrCast(opaque_ptr: *anyopaque, comptime T: type) *T {
    const aligned = @alignCast(@alignOf(T), opaque_ptr);
    return @ptrCast(*T, aligned);
}

test {
    _ = AudioPipeline;
    _ = @import("./uuid.zig");
    _ = @import("./structures/MultiRingBuffer.zig");
    _ = @import("./Evaluator.zig");
}

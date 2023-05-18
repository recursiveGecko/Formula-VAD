const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioPipeline = @import("AudioPipeline.zig");
const AudioFileStream = @import("audio_utils/AudioFileStream.zig");
const VAD = @import("AudioPipeline/VAD.zig");
const clap = @import("clap");
const Evaluator = @import("Evaluator.zig");

const fs = std.fs;
const log = std.log.scoped(.simulator);
const exit = std.os.exit;
const stderr = std.io.getStdErr();
const stdout = std.io.getStdOut();
const stderr_w = stdout.writer();
const stdout_w = stdout.writer();

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

pub fn runVADSingle(allocator: Allocator, stream: *AudioFileStream) ![]Evaluator.SpeechSegment {
    const pipeline = try AudioPipeline.init(allocator, .{
        .sample_rate = stream.sample_rate,
        .n_channels = stream.n_channels,
        .vad_config = .{},
    });
    defer pipeline.deinit();

    const sample_rate = stream.sample_rate;
    const frame_size = sample_rate / 10;

    // The backing slice of slices for our audio samples
    var backing_channel_pcm = try allocator.alloc([]f32, stream.n_channels);
    // The slice we'll pass to the audio pipeline, trimmed to the actual number of samples read.
    var trimmed_channel_pcm = try allocator.alloc([]f32, stream.n_channels);
    var channels_allocated: usize = 0;
    defer {
        for (0..channels_allocated) |i| allocator.free(backing_channel_pcm[i]);
        allocator.free(backing_channel_pcm);
        allocator.free(trimmed_channel_pcm);
    }
    // Initialize the backing channel slices
    for (0..backing_channel_pcm.len) |i| {
        backing_channel_pcm[i] = try allocator.alloc(f32, frame_size);
        channels_allocated += 1;
    }

    // Read frames and pass them to the AudioPipeline
    var total_samples_read: usize = 0;
    while (true) {
        const samples_read = try stream.read(backing_channel_pcm, frame_size, 0);
        if (samples_read == 0) break;

        for (0..stream.n_channels) |i| {
            trimmed_channel_pcm[i] = backing_channel_pcm[i][0..samples_read];
        }

        try pipeline.pushSamples(trimmed_channel_pcm);
        total_samples_read += samples_read;
    }

    log.info("Processed: {d} samples", .{total_samples_read});

    const vad_segments = try pipeline.vad.?.vad_segments.toOwnedSlice();
    defer allocator.free(vad_segments);

    var speech_segments = try allocator.alloc(Evaluator.SpeechSegment, vad_segments.len);
    errdefer allocator.free(speech_segments);

    for (vad_segments, 0..) |vad_segment, i| {
        const from_sec = @intToFloat(f32, vad_segment.sample_from) / @intToFloat(f32, sample_rate);
        const to_sec = @intToFloat(f32, vad_segment.sample_to) / @intToFloat(f32, sample_rate);

        const debug_info = try std.fmt.allocPrint(allocator, "rnn:{d:.2}%", .{vad_segment.debug_rnn_vad * 100});

        speech_segments[i] = .{
            .from_sec = from_sec,
            .to_sec = to_sec,
            .debug_info = debug_info,
        };
    }

    return speech_segments;
}

const params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    \\-i, --input <str>      Input audio file for VAD evaluation.
    \\-r, --reference <str>  Reference segment file to evaluate against.
    \\-o, --output <str>     Output file to write speech segments to.
    \\
);

fn printHelp() !void {
    try clap.help(stdout_w, clap.Help, &params, .{});
}

/// Entrypoint for CLI invocation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

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

    const input_file_path_Z = try allocator.dupeZ(u8, input_file_path.?);
    defer allocator.free(input_file_path_Z);

    const megabyte = 1024 * 1024;

    // Read inputs and maybe create output
    const ref_contents = try fs.Dir.readFileAlloc(fs.cwd(), allocator, ref_file_path.?, 10 * megabyte);
    defer allocator.free(ref_contents);

    var out_file = if (res.args.output) |of| try fs.Dir.createFile(fs.cwd(), of, .{}) else null;

    var audio_stream = try AudioFileStream.open(allocator, input_file_path_Z);
    defer audio_stream.close();

    const ref_segments = try Evaluator.parseAudacityTxt(allocator, ref_contents);
    defer allocator.free(ref_segments);

    log.info("Streaming {d:.2}s from audio file. Running...", .{audio_stream.lengthSeconds()});

    // Run VAD and evaluate results
    const simulated_segments = try runVADSingle(allocator, &audio_stream);
    defer allocator.free(simulated_segments);

    var evaluator = try Evaluator.initAndRun(allocator, simulated_segments, ref_segments);
    defer evaluator.deinit();

    const stats = evaluator.buildStatistics();

    try stdout_w.print("Statistics:\n", .{});
    try stdout_w.print("Real events:     {}\n", .{stats.total_reference_events});
    try stdout_w.print("VAD events:      {}\n", .{stats.total_input_events});
    try stdout_w.print("True positives:  {}\n", .{stats.true_positives});
    try stdout_w.print("False positives: {}\n", .{stats.false_positives});
    try stdout_w.print("False negatives: {}\n", .{stats.false_negatives});

    // Maybe write output segments
    if (out_file) |out_f| {
        defer out_f.close();

        var out_fw = out_f.writer();

        for (evaluator.input_segments) |segment| {
            const comment = try segment.toComment(allocator);
            defer allocator.free(comment);

            try out_fw.print("{d:.4}\t{d:.4}\t{s}\n", .{ segment.from_sec, segment.to_sec, comment });
        }

        for (evaluator.reference_segments) |segment| {
            if (segment.match == .matched) continue;
            try out_fw.print("{d:.4}\t{d:.4}\t{s}\n", .{ segment.from_sec, segment.to_sec, "missed" });
        }
    }
}

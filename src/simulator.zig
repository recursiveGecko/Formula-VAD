const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioPipeline = @import("AudioPipeline.zig");
const AudioBuffer = @import("audio_utils/AudioBuffer.zig");
const VAD = @import("AudioPipeline/VAD.zig");
const clap = @import("clap");
const Evaluator = @import("Evaluator.zig");

const fs = std.fs;
const exit = std.os.exit;
var stderr = std.io.getStdErr();
var stdout = std.io.getStdOut();

pub fn runVADSingle(allocator: Allocator, file: AudioBuffer) ![]Evaluator.SpeechSegment {
    const pipeline = try AudioPipeline.init(allocator, .{
        .sample_rate = file.sample_rate,
        .n_channels = file.n_channels,
    });
    defer pipeline.deinit();

    const sample_rate = file.sample_rate;
    const frame_size = 2048;
    const steps = file.length / frame_size + @boolToInt(file.length % frame_size != 0);

    var framed_channel_pcm = try allocator.alloc([]f32, file.n_channels);
    defer allocator.free(framed_channel_pcm);

    for (0..steps) |step_idx| {
        const from = step_idx * frame_size;
        const to = @min(file.length, from + frame_size);

        for (0..file.n_channels) |channel_idx| {
            framed_channel_pcm[channel_idx] = file.channel_pcm_buf[channel_idx][from..to];
        }

        try pipeline.pushSamples(framed_channel_pcm);
    }

    const vad_segments = try pipeline.vad.?.vad_segments.toOwnedSlice();
    defer allocator.free(vad_segments);

    var speech_segments = try allocator.alloc(Evaluator.SpeechSegment, vad_segments.len);
    errdefer allocator.free(speech_segments);

    for (vad_segments, 0..) |vad_segment, i| {
        const from_sec = @intToFloat(f32, vad_segment.sample_from) / @intToFloat(f32, sample_rate);
        const to_sec = @intToFloat(f32, vad_segment.sample_to) / @intToFloat(f32, sample_rate);

        speech_segments[i] = .{
            .from_sec = from_sec,
            .to_sec = to_sec,
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
    try clap.help(stdout.writer(), clap.Help, &params, .{});
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

    var audio_buffer = try AudioBuffer.loadFromFile(allocator, input_file_path_Z);
    defer audio_buffer.deinit();

    const ref_segments = try Evaluator.parseAudacityTxt(allocator, ref_contents);
    defer allocator.free(ref_segments);

    try stdout.writer().print("Loaded {} samples from audio file. Running...\n", .{audio_buffer.length});

    // Run VAD and evaluate results
    const simulated_segments = try runVADSingle(allocator, audio_buffer);
    defer allocator.free(simulated_segments);

    var evaluator = try Evaluator.initAndRun(allocator, simulated_segments, ref_segments);
    defer evaluator.deinit();

    const stats = evaluator.buildStatistics();
    std.debug.print("{any}", .{stats});

    // Maybe write output segments
    if (out_file) |out| {
        var ow = out.writer();
        defer out.close();

        for (evaluator.input_segments) |segment| {
            try ow.print("{d:.4}\t{d:.4}\t{s}\n", .{ segment.from_sec, segment.to_sec, @tagName(segment.match) });
        }
    }
}

const std = @import("std");
const log = std.log.scoped(.pipeline);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const PipelineFFT = @import("./AudioPipeline/PipelineFFT.zig");
const Segment = @import("./AudioPipeline/Segment.zig");
const Recorder = @import("./AudioPipeline/Recorder.zig");
const SplitSlice = @import("./structures/SplitSlice.zig").SplitSlice;
const MultiRingBuffer = @import("./structures/MultiRingBuffer.zig").MultiRingBuffer;
pub const VAD = @import("./AudioPipeline/VAD.zig");
pub const AudioBuffer = @import("./audio_utils/AudioBuffer.zig");

const Self = @This();

pub const Callbacks = struct {
    ctx: *anyopaque,
    on_recording: ?*const fn (ctx: *anyopaque, recording: *const AudioBuffer) void,
};

pub const Config = struct {
    sample_rate: usize,
    n_channels: usize,
    buffer_length: ?usize = null,
    vad_config: VAD.Config = .{},
    skip_processing: bool = false,
};

allocator: Allocator,
config: Config,
multi_ring_buffer: MultiRingBuffer(f32, u64),
recorder: Recorder,
/// Slice of slices that temporarily holds the samples to be recorded.
temp_record_slices: []SplitSlice(f32),
vad: VAD = undefined,
callbacks: ?Callbacks = null,

pub fn init(
    allocator: Allocator,
    config: Config,
    callbacks: ?Callbacks,
) !*Self {
    // TODO: Calculate a more optional length?
    const buffer_length = config.buffer_length orelse config.sample_rate * 10;

    var multi_ring_buffer = try MultiRingBuffer(f32, u64).init(
        allocator,
        config.n_channels,
        buffer_length,
    );
    errdefer multi_ring_buffer.deinit();

    var recorder = try Recorder.init(allocator, config.n_channels, config.sample_rate);
    errdefer recorder.deinit();

    var temp_record_slices = try allocator.alloc(SplitSlice(f32), config.n_channels);
    errdefer allocator.free(temp_record_slices);

    var self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = std.mem.zeroInit(Self, .{
        .config = config,
        .allocator = allocator,
        .multi_ring_buffer = multi_ring_buffer,
        .temp_record_slices = temp_record_slices,
        .recorder = recorder,
        .callbacks = callbacks,
    });

    self.vad = try VAD.init(self, config.vad_config);
    errdefer self.vad.deinit();

    return self;
}

pub fn deinit(self: *Self) void {
    self.vad.deinit();
    self.multi_ring_buffer.deinit();
    self.allocator.free(self.temp_record_slices);
    self.recorder.deinit();
    self.allocator.destroy(self);
}

pub fn pushSamples(self: *Self, channel_pcm: []const []const f32) !u64 {
    const first_sample_index = self.multi_ring_buffer.total_write_count;

    const n_samples = channel_pcm[0].len;
    // Write in chunks of `write_chunk_size` samples to ensure we don't
    // write too much data before processing it
    const write_chunk_size = self.multi_ring_buffer.capacity / 2;
    var read_offset: usize = 0;
    while (true) {
        // We record as many samples as we're going to write, to
        // ensure we don't lose any.
        if (self.recorder.isRecording()) {
            const buffer_capacity = self.multi_ring_buffer.capacity;
            const exp_step_write_count = @min(n_samples - read_offset, write_chunk_size);
            const exp_step_write_index = self.multi_ring_buffer.total_write_count + exp_step_write_count;

            if (exp_step_write_index > buffer_capacity) {
                const record_until_sample = exp_step_write_index - buffer_capacity;
                _ = try self.maybeRecordBuffer(record_until_sample);
            }
        }

        const n_written = self.multi_ring_buffer.writeAssumeCapacity(
            channel_pcm,
            read_offset,
            write_chunk_size,
        );
        read_offset += n_written;

        try self.maybeRunPipeline();
        if (n_written < write_chunk_size) break;
    }

    return first_sample_index;
}

/// Slice samples using absolute indices, from `abs_from` inclusive to `abs_to` exclusive.
pub fn sliceSegment(self: Self, result_segment: *Segment, abs_from: u64, abs_to: u64) !void {
    try self.multi_ring_buffer.readSlice(
        result_segment.channel_pcm_buf,
        abs_from,
        abs_to,
    );

    result_segment.*.index = abs_from;
    result_segment.*.length = abs_to - abs_from;
}

pub fn beginCapture(self: *Self, vad_from_sample: usize) !void {
    // Add a couple of seconds of buffer to the start of the recording to avoid missing the start
    const start_buffer = self.config.sample_rate * 2;
    var actual_start_sample = if (start_buffer > vad_from_sample) 0 else vad_from_sample - start_buffer;

    self.recorder.start(actual_start_sample);
}

pub fn endCapture(self: *Self, vad_to_sample: usize, keep: bool) !void {
    // Ensure we're not cutting off mid-speech
    var actual_end_sample = vad_to_sample + self.config.sample_rate * 2;

    if (keep) {
        _ = try self.maybeRecordBuffer(actual_end_sample);
    }

    var maybe_audio_buffer = try self.recorder.finalize(actual_end_sample, keep);
    if (!keep) return;

    if (maybe_audio_buffer) |*audio_buffer| {
        defer audio_buffer.deinit();

        const cb_config = self.callbacks orelse return;
        if (cb_config.on_recording) |cb| {
            cb(cb_config.ctx, audio_buffer);
        }
    } else {
        log.err("Expected to capture segment, but none was returned", .{});
    }
}

pub fn durationToSamples(sample_rate: usize, buffer_duration: f32) usize {
    const duration_f = (@intToFloat(f32, sample_rate) * buffer_duration);
    return @floatToInt(usize, @ceil(duration_f));
}

fn maybeRunPipeline(self: *Self) !void {
    if (self.config.skip_processing) return;

    try self.vad.run();
}

fn maybeRecordBuffer(self: *Self, to_sample: usize) !bool {
    if (!self.recorder.isRecording()) return false;

    const from_sample = self.recorder.endIndex();

    if (to_sample <= from_sample) return true;

    var record_segment = Segment{
        .allocator = null,
        .channel_pcm_buf = self.temp_record_slices,
        .index = from_sample,
        .length = to_sample - from_sample,
    };

    try self.sliceSegment(&record_segment, from_sample, to_sample);
    try self.recorder.write(&record_segment);
    return true;
}

//
// Tests
//

test {
    _ = @import("./AudioPipeline/SegmentWriter.zig");
}

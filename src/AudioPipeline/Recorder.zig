const std = @import("std");
const log = std.log.scoped(.recorder);
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const AudioBuffer = @import("../audio_utils/AudioBuffer.zig");
const audio_utils = @import("../audio_utils.zig");

const Self = @This();

allocator: Allocator,
n_channels: usize,
sample_rate: usize,
status: enum { idle, recording } = .idle,
segment_writer: SegmentWriter,
last_recording_end_index: u64 = 0,

pub fn init(allocator: Allocator, n_channels: usize, sample_rate: usize) !Self {
    const initial_length = sample_rate * 10;

    const self = Self{
        .allocator = allocator,
        .n_channels = n_channels,
        .sample_rate = sample_rate,
        .segment_writer = try SegmentWriter.init(allocator, n_channels, initial_length),
    };

    return self;
}

pub fn deinit(self: *Self) void {
    self.segment_writer.deinit();
}

pub fn isRecording(self: Self) bool {
    return self.status == .recording;
}

pub fn currentCapacity(self: Self) usize {
    return self.segment_writer.internal_segment.length();
}

/// Index of the first saved frame (sample) in the recording
pub fn startIndex(self: Self) u64 {
    return self.segment_writer.segment_view.index;
}

/// Index following the last saved frame (sample) in the recording
pub fn endIndex(self: Self) u64 {
    return self.segment_writer.segment_view.index + self.segment_writer.segment_view.length();
}

pub fn start(self: *Self, start_index: u64) void {
    log.info("Starting recording. start_index: {d}", .{start_index});

    self.segment_writer.reset(start_index);
    self.status = .recording;
}

pub fn write(self: *Self, segment: *const Segment) !void {
    const required_length = self.segment_writer.write_index + segment.length();

    if (required_length > self.currentCapacity()) {
        // When resizing, add at least 10 seconds worth of samples to the current capacity.
        const new_length = @max(required_length, self.currentCapacity() + self.sample_rate * 10);
        try self.segment_writer.resize(new_length);
    }

    const written = try self.segment_writer.write(segment, 0);
    std.debug.assert(written == segment.length());
}

pub fn finalize(self: *Self, to_frame: u64, keep: bool) !?AudioBuffer {
    defer {
        self.segment_writer.reset(0);
        self.status = .idle;
    }

    log.info("Finalizing recording. to_frame: {d}, keep: {}", .{ to_frame, keep });

    if (keep) {
        const recording_start_idx = self.startIndex();
        const last_recorded_idx = self.endIndex();

        if (to_frame > last_recorded_idx) {
            log.err("Recorder is missing data. to_frame: {d}, last_recorded_idx: {d}", .{ to_frame, last_recorded_idx });
            // Data needs to be written before finalize() is called.
            return error.MissingData;
        }

        if (to_frame < recording_start_idx) {
            log.err("Recording end index before start. to_frame: {d}, recording_start_idx: {d}", .{ to_frame, recording_start_idx });
            return error.InvalidEndIndex;
        }

        const n_to_keep = to_frame - self.startIndex();
        var segment = self.segment_writer.segment_view;
        try segment.clipView(0, n_to_keep);

        const audio_buffer = try segmentToAudioBuffer(self.allocator, segment, self.sample_rate);

        self.last_recording_end_index = to_frame;
        return audio_buffer;
    } else {
        // If we're not keeping the data, we can just reset the write index. (defer above)
        return null;
    }
}

fn findBestChannel(segment: Segment) usize {
    var best_channel: usize = 0;
    var best_channel_vol: f32 = 9999;

    const n_channels = segment.channel_pcm_buf.len;

    for (0..n_channels) |i| {
        const vol = audio_utils.rmsVolume(segment.channel_pcm_buf[i]);
        if (vol < best_channel_vol) {
            best_channel = i;
            best_channel_vol = vol;
        }
    }

    return best_channel;
}

fn segmentToAudioBuffer(
    allocator: Allocator,
    segment: Segment,
    sample_rate: usize,
) !AudioBuffer {
    const best_channel_idx = findBestChannel(segment);

    const channel_pcm_buf = try allocator.alloc([]f32, 1);
    errdefer allocator.free(channel_pcm_buf);

    const src_channel = segment.channel_pcm_buf[best_channel_idx];
    const dst_channel = try allocator.alloc(f32, segment.length());
    errdefer allocator.free(dst_channel);

    // copy best channel
    @memcpy(dst_channel, src_channel);
    channel_pcm_buf[0] = dst_channel;

    const duration_sec = @as(f32, @floatFromInt(segment.length())) / @as(f32, @floatFromInt(sample_rate));

    const audio_buffer = AudioBuffer{
        .allocator = allocator,
        .length = segment.length(),
        .sample_rate = sample_rate,
        .n_channels = 1,
        .duration_seconds = duration_sec,
        .channel_pcm_buf = channel_pcm_buf,
        .global_start_frame_number = segment.index,
    };

    return audio_buffer;
}

//! MRBRecorder (Multi Ring Buffer Recorder) is responsible for
//! correctly recording audio from a MultiRingBuffer as
//! new samples are written to it, ensuring that samples
//! are not overwritten before they are recorded.
//!
//! It also allows for recording to be stopped at a future sample index,
//! at which point the recording is automatically finalized.
//!
//! After recording is finalized, MRBRecorder calls the provided callback,
//! passing it the recorded audio as an AudioBuffer which the CALLEE
//! must deinit/free.
//!
const std = @import("std");
const log = std.log.scoped(.mrb_recorder);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Segment = @import("./Segment.zig");
const AudioBuffer = @import("../audio_utils/AudioBuffer.zig");
const SegmentWriter = @import("./SegmentWriter.zig");
const MultiRingBuffer = @import("../structures/MultiRingBuffer.zig").MultiRingBuffer;
const types = @import("../types.zig");
const audio_utils = @import("../audio_utils.zig");

const Self = @This();

pub const RecordingCB = fn (ctx: *anyopaque, audio_buffer: *AudioBuffer) void;

allocator: Allocator,
n_channels: usize,
sample_rate: usize,
multi_ring_buffer: *MultiRingBuffer(f32, u64),
segment_writer: SegmentWriter,
recording_cb: *const RecordingCB,
recording_cb_ctx: *anyopaque,
status: enum { idle, recording } = .idle,
end_recording_on_sample: ?u64 = null,
last_recording_end_index: u64 = 0,

pub fn init(
    allocator: Allocator,
    multi_ring_buffer: *MultiRingBuffer(f32, u64),
    sample_rate: usize,
    recording_cb: *const RecordingCB,
    recording_cb_ctx: *anyopaque,
) !Self {
    const n_channels = multi_ring_buffer.n_channels;
    const initial_length = sample_rate * 5;

    var segment_writer = try SegmentWriter.init(allocator, n_channels, initial_length);
    errdefer segment_writer.deinit();

    return Self{
        .allocator = allocator,
        .n_channels = n_channels,
        .sample_rate = sample_rate,
        .multi_ring_buffer = multi_ring_buffer,
        .segment_writer = segment_writer,
        .recording_cb = recording_cb,
        .recording_cb_ctx = recording_cb_ctx,
    };
}

pub fn deinit(self: *Self) void {
    self.segment_writer.deinit();
}

/// Index of the first saved frame (sample) in the recording
pub fn startIndex(self: Self) u64 {
    return self.segment_writer.segment_view.index;
}

/// Index following the last saved frame (sample) in the recording
pub fn endIndex(self: Self) u64 {
    return self.startIndex() + self.segment_writer.writtenCount();
}

pub fn startRecording(self: *Self, from_sample: u64) !void {
    if (self.end_recording_on_sample != null) {
        log.info(
            "Recording was scheduled to stop at sample {d} but has been restarted at sample {d}",
            .{ self.end_recording_on_sample.?, from_sample },
        );
        self.end_recording_on_sample = null;
    }

    self.segment_writer.reset(from_sample);
    self.status = .recording;
}

pub fn stopRecording(self: *Self, to_sample: u64, keep: bool) !void {
    if (self.status == .idle) {
        log.err("stopRecording() was called but recording is not in progress", .{});
        return error.NotRecording;
    }

    if (keep and self.startIndex() > to_sample) {
        log.err(
            "stopRecording() was called with to_sample {} before startIndex {}",
            .{ to_sample, self.startIndex() },
        );
        return error.EndIndexBeforeStart;
    }

    if (keep) {
        // Schedule the recording to be finalized after we record the specified sample index.
        self.end_recording_on_sample = to_sample;
        // Try to finalize the recording now, in case we already have the samples we need.
        try self.maybeFinalizeRecording();
    } else {
        // Stop recording immediately and discard the recording.
        self.end_recording_on_sample = null;
        _ = try self.finalize(to_sample, false);
    }
}

/// Records any samples that would be overwritten by the next write to the MultiRingBuffer
pub fn beforeMRBWrite(self: *Self, next_write_head: usize) !void {
    if (self.status != .recording) return;

    // If we're waiting for samples to arrive before we can finalize the recording,
    // check if we can finalize it now.
    try self.maybeFinalizeRecording();

    // Minimum sample index to record up to, i.e. the samples that are going to be overwritten
    try self.maybeRecordBuffer(next_write_head);
}

/// Tries to record samples up to the specified sample index (if they are available).
fn maybeRecordBuffer(self: *Self, suggested_to_idx: usize) !void {
    if (self.status != .recording) return;

    // If we've already recorded up to, or beyond this sample index,
    // there's nothing to do.
    const next_sample_idx = self.endIndex();
    if (suggested_to_idx <= next_sample_idx) return;

    const record_to_idx = @min(
        suggested_to_idx,
        self.multi_ring_buffer.total_write_count,
    );
    // If we already recorded everything we can currently record,
    // there's nothing to do.
    if (record_to_idx <= next_sample_idx) return;

    log.debug("Recording [ {d:10} - {d:10} ]\n", .{ next_sample_idx, record_to_idx });

    // Read the slice from the ring buffer and record it.
    const split_slice = try self.multi_ring_buffer.sliceBuffer(
        next_sample_idx,
        record_to_idx,
    );
    defer split_slice.release();

    const split_segments = types.splitSliceToSegments(split_slice);
    try self.write(&split_segments.first);
    try self.write(&split_segments.second);
}

fn write(self: *Self, segment: *const Segment) !void {
    const required_length = self.segment_writer.writtenCount() + segment.length();

    // Maybe extend the buffer to fit our new segment
    if (required_length > self.segment_writer.capacity()) {
        // When resizing, add at least 10 seconds worth of samples to the current capacity.
        const new_length = @max(required_length, self.segment_writer.capacity() + self.sample_rate * 2);
        try self.segment_writer.resize(new_length);
    }

    const written = try self.segment_writer.write(segment, 0);
    std.debug.assert(written == segment.length());
}

/// Tries to finalize the recording if we have the samples we need,
/// tries to record the missing samples otherwise.
fn maybeFinalizeRecording(self: *Self) !void {
    // If we're not recording, or not in the process of finalizing, there's nothing to do.
    if (self.status != .recording) return;
    if (self.end_recording_on_sample == null) return;

    // Index we need to record up to before we can finalize the recording.
    const finalize_after_idx = self.end_recording_on_sample.?;

    // Try to record up to the index we need to finalize the recording.
    try self.maybeRecordBuffer(finalize_after_idx);

    // Index we've already recorded up to.
    const last_recorded_idx = self.endIndex();

    // If we haven't recorded up to the index we need to finalize the recording,
    // there's nothing to do yet.
    if (last_recorded_idx < finalize_after_idx) return;

    self.end_recording_on_sample = null;

    // Finalize the recording and call the callback with the recorded audio buffer.
    var maybe_audio_buffer = self.finalize(finalize_after_idx, true) catch |err| {
        log.err("Failed to finalize recording: {any}", .{err});
        return err;
    };

    if (maybe_audio_buffer) |*audio_buffer| {
        self.recording_cb(self.recording_cb_ctx, audio_buffer);
    } else {
        log.err("Expected to capture segment, but none was returned", .{});
    }
}

fn finalize(self: *Self, to_frame: u64, keep: bool) !?AudioBuffer {
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

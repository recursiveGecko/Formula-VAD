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
const Recorder = @import("./Recorder.zig");
const AudioBuffer = @import("../audio_utils/AudioBuffer.zig");
const SplitSlice = @import("../structures/SplitSlice.zig").SplitSlice;
const MultiRingBuffer = @import("../structures/MultiRingBuffer.zig").MultiRingBuffer;

const Self = @This();

pub const RecordingCB = fn (ctx: *anyopaque, audio_buffer: *AudioBuffer) void;

allocator: Allocator,
multi_ring_buffer: *const MultiRingBuffer(f32, u64),
recorder: Recorder,
/// Slice of slices that temporarily holds the samples to be recorded.
temp_record_slices: []SplitSlice(f32),
n_channels: usize,
sample_rate: usize,
end_recording_on_sample: ?u64 = null,
recording_cb: *const RecordingCB,
recording_cb_ctx: *anyopaque,

pub fn init(
    allocator: Allocator,
    multi_ring_buffer: *const MultiRingBuffer(f32, u64),
    sample_rate: usize,
    recording_cb: *const RecordingCB,
    recording_cb_ctx: *anyopaque,
) !Self {
    const n_channels = multi_ring_buffer.*.n_channels;
    var recorder = try Recorder.init(
        allocator,
        n_channels,
        sample_rate,
    );
    errdefer recorder.deinit();

    var temp_record_slices = try allocator.alloc(
        SplitSlice(f32),
        n_channels,
    );
    errdefer allocator.free(temp_record_slices);

    return Self{
        .allocator = allocator,
        .n_channels = n_channels,
        .sample_rate = sample_rate,
        .multi_ring_buffer = multi_ring_buffer,
        .recorder = recorder,
        .temp_record_slices = temp_record_slices,
        .recording_cb = recording_cb,
        .recording_cb_ctx = recording_cb_ctx,
    };
}

pub fn deinit(self: *Self) void {
    self.recorder.deinit();
    self.allocator.free(self.temp_record_slices);
}

pub fn startRecording(self: *Self, from_sample: u64) !void {
    if (self.end_recording_on_sample != null) {
        log.info(
            "Recording was scheduled to stop at sample {d} but has been restarted at sample {d}",
            .{ self.end_recording_on_sample.?, from_sample },
        );
        self.end_recording_on_sample = null;
    }

    self.recorder.start(from_sample);
}

pub fn stopRecording(self: *Self, to_sample: u64, keep: bool) !void {
    if (!self.recorder.isRecording()) {
        log.err("stopRecording() was called but recording is not in progress", .{});
        return error.NotRecording;
    }

    if (keep and self.recorder.startIndex() > to_sample) {
        log.err(
            "stopRecording() was called with to_sample {} before startIndex {}",
            .{ to_sample, self.recorder.startIndex() },
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
        _ = try self.recorder.finalize(to_sample, false);
    }
}

/// Records any samples that would be overwritten by the next write to the MultiRingBuffer
pub fn recordBeforeMRBWrite(self: *Self, n_samples_to_write: usize) !void {
    if (!self.recorder.isRecording()) return;

    // If we're waiting for samples to arrive before we can finalize the recording,
    // check if we can finalize it now.
    try self.maybeFinalizeRecording();

    // Expected sample write index after this batch of samples is written to the ring buffer.
    // This allows us to determine the last sample that's going to be overwritten
    const write_index_after_write = self.multi_ring_buffer.total_write_count + n_samples_to_write;
    const ring_buffer_capacity = self.multi_ring_buffer.capacity;

    if (write_index_after_write < ring_buffer_capacity) {
        // We are not going to overwrite any samples, so we don't need to record anything.
        return;
    }

    // Minimum sample index to record up to, i.e. the samples that are going to be overwritten
    const record_until_sample = write_index_after_write - ring_buffer_capacity;
    try self.maybeRecordBuffer(record_until_sample);
}

/// Tries to record samples up to the specified sample index (if they are available).
fn maybeRecordBuffer(self: *Self, suggested_to_idx: usize) !void {
    if (!self.recorder.isRecording()) return;

    // If we've already recorded up to, or beyond this sample index,
    // there's nothing to do.
    const last_recorded_idx = self.recorder.endIndex();
    if (suggested_to_idx <= last_recorded_idx) return;

    const record_to_idx = @min(
        suggested_to_idx,
        self.multi_ring_buffer.total_write_count,
    );
    // If we already recorded everything we can currently record,
    // there's nothing to do.
    if (record_to_idx <= last_recorded_idx) return;

    var record_segment = Segment{
        .allocator = null,
        .channel_pcm_buf = self.temp_record_slices,
        .index = last_recorded_idx,
        .length = record_to_idx - last_recorded_idx,
    };

    // Read the slice from the ring buffer and record it.
    try self.multi_ring_buffer.readSlice(
        self.temp_record_slices,
        last_recorded_idx,
        record_to_idx,
    );
    try self.recorder.write(&record_segment);
}

/// Tries to finalize the recording if we have the samples we need,
/// tries to record the missing samples otherwise.
fn maybeFinalizeRecording(self: *Self) !void {
    // If we're not recording, or not in the process of finalizing, there's nothing to do.
    if (!self.recorder.isRecording()) return;
    if (self.end_recording_on_sample == null) return;

    // Index we need to record up to before we can finalize the recording.
    const finalize_after_idx = self.end_recording_on_sample.?;

    // Try to record up to the index we need to finalize the recording.
    try self.maybeRecordBuffer(finalize_after_idx);

    // Index we've already recorded up to.
    const last_recorded_idx = self.recorder.endIndex();

    // If we haven't recorded up to the index we need to finalize the recording,
    // there's nothing to do yet.
    if (last_recorded_idx < finalize_after_idx) return;

    self.end_recording_on_sample = null;

    // Finalize the recording and call the callback with the recorded audio buffer.
    var maybe_audio_buffer = self.recorder.finalize(finalize_after_idx, true) catch |err| {
        log.err("Failed to finalize recording: {any}", .{err});
        return err;
    };

    if (maybe_audio_buffer) |*audio_buffer| {
        self.recording_cb(self.recording_cb_ctx, audio_buffer);
    } else {
        log.err("Expected to capture segment, but none was returned", .{});
    }
}

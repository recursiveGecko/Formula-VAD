const std = @import("std");
const Allocator = std.mem.Allocator;
const onnx = @import("onnxruntime");
const resample = @import("audio_utils/resample.zig");

const on_threshold: f32 = 0.5;
const off_threshold: f32 = on_threshold - 0.15;
const min_speech_duration_ms: f32 = 1000;
const max_silence_between_speech_ms: f32 = 1500;

// Hard-coded sample rate, this is what the model needs
const model_sample_rate = 16000;
// This is defined in the original repo, the model works best
// with certain sizes of windows.

// const window_size_samples: usize = 1024; // 64ms
const window_size_samples: usize = 512; // 32ms

pub const Result = union(enum) {
    ok: struct {},
    start_speech: struct {
        start_sample: usize,
    },
    end_speech: struct {
        end_sample: usize,
    },
};

const Self = @This();

const Status = enum { closed, opening, open, closing };

allocator: std.mem.Allocator,
onnx_instance: *onnx.OnnxInstance,
in_sample_rate: usize,
// Model inputs/outputs
pcm: []f32,
sr: []i64,
h: []f32,
c: []f32,
vad: []f32,
hn: []f32,
cn: []f32,
start_sample: ?usize = null,
end_sample: ?usize = null,
status: Status = .closed,
awaiting_close: bool = false,

pub fn init(
    allocator: Allocator,
    in_sample_rate: usize,
) !Self {
    if (in_sample_rate % model_sample_rate != 0) {
        @panic("Input sample rate must be a multiple of model_sample_rate");
    }

    // Initialize ONNX runtime

    const onnx_opts = onnx.OnnxInstanceOpts{
        .log_id = "ZIG",
        .log_level = .warning,
        .model_path = "data/silero_vad.onnx",
        .input_names = &.{ "input", "sr", "h", "c" },
        .output_names = &.{ "output", "hn", "cn" },
    };
    const onnx_instance = try onnx.OnnxInstance.init(allocator, onnx_opts);
    try onnx_instance.initMemoryInfo("Cpu", .arena, 0, .default);
    errdefer onnx_instance.deinit();

    // PCM input
    const pcm_node_dimms: []const i64 = &.{ 1, window_size_samples };
    const pcm = try allocator.alloc(f32, window_size_samples);
    errdefer allocator.free(pcm);
    @memset(pcm, 0);
    const pcm_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        pcm,
        pcm_node_dimms,
        .f32,
    );

    // Sample rate input
    const sr_node_dimms: []const i64 = &.{1};
    const sr: []i64 = try allocator.dupe(i64, &.{model_sample_rate});
    errdefer allocator.free(sr);
    const sr_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
        i64,
        sr,
        sr_node_dimms,
        .i64,
    );

    // Hidden and cell state inputs
    const size_hc: usize = 2 * 1 * 64;
    const hc_node_dimms: []const i64 = &.{ 2, 1, 64 };

    const h = try allocator.alloc(f32, size_hc);
    errdefer allocator.free(h);
    @memset(h, 0);
    const h_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        h,
        hc_node_dimms,
        .f32,
    );

    const c = try allocator.alloc(f32, size_hc);
    errdefer allocator.free(c);
    @memset(c, 0);
    const c_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        c,
        hc_node_dimms,
        .f32,
    );
    const ort_inputs = try allocator.dupe(*onnx.c_api.OrtValue, &.{
        pcm_ort_input,
        sr_ort_input,
        h_ort_input,
        c_ort_input,
    });

    // Set up outputs
    const vad = try allocator.alloc(f32, 1);
    errdefer allocator.free(vad);
    @memset(vad, 0);
    const vad_ort_output = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        vad,
        &.{ 1, 1 },
        .f32,
    );

    const hn = try allocator.alloc(f32, size_hc);
    errdefer allocator.free(hn);
    @memset(hn, 0);
    const hn_ort_output = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        hn,
        hc_node_dimms,
        .f32,
    );

    const cn = try allocator.alloc(f32, size_hc);
    errdefer allocator.free(cn);
    @memset(cn, 0);
    const cn_ort_output = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        cn,
        hc_node_dimms,
        .f32,
    );

    const ort_outputs = try allocator.dupe(?*onnx.c_api.OrtValue, &.{
        vad_ort_output,
        hn_ort_output,
        cn_ort_output,
    });

    onnx_instance.setManagedInputsOutputs(ort_inputs, ort_outputs);

    const self = Self{
        .allocator = allocator,
        .in_sample_rate = in_sample_rate,
        // model inputs/outputs
        .onnx_instance = onnx_instance,
        .pcm = pcm,
        .sr = sr,
        .h = h,
        .c = c,
        .vad = vad,
        .hn = hn,
        .cn = cn,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    self.onnx_instance.deinit();
    self.allocator.free(self.pcm);
    self.allocator.free(self.sr);
    self.allocator.free(self.h);
    self.allocator.free(self.c);
    self.allocator.free(self.vad);
    self.allocator.free(self.hn);
    self.allocator.free(self.cn);
}

pub fn getChunkSize(self: *Self) usize {
    return getChunkSizeForSR(self.in_sample_rate);
}

pub fn getChunkSizeForSR(in_sample_rate: usize) usize {
    const downsample_rate = resample.calcDownsampleRate(in_sample_rate, model_sample_rate);
    return window_size_samples * downsample_rate;
}

pub fn runVAD(self: *Self, samples: []const f32, first_sample_index: usize) !Result {
    const downsample_rate = resample.calcDownsampleRate(self.in_sample_rate, model_sample_rate);
    resample.downsampleAudio(samples, self.pcm, downsample_rate);

    try self.onnx_instance.run();

    // Output VAD value
    const vad = self.vad[0];

    // Copy the hidden and cell states for the next iteration
    @memcpy(self.h, self.hn);
    @memcpy(self.c, self.cn);

    const last_sample_index = first_sample_index + samples.len() - 1;

    switch (self.status) {
        .closed => {
            if (vad >= on_threshold) {
                // 1. Start opening sequence
                self.start_sample = first_sample_index;
                self.status = .opening;
            }
        },
        .opening => {
            const speech_duration_samples_f: f32 = @floatFromInt(last_sample_index - self.start_sample.?);
            const samples_per_ms = @as(f32, @floatFromInt(self.in_sample_rate)) / 1000;
            const speech_duration_ms = speech_duration_samples_f / samples_per_ms;

            // std.debug.print("{any} - {d:.2} - {d:.1}\n", .{ self.status, vad, speech_duration_ms });

            if (vad < on_threshold) {
                self.status = .closing;
                self.end_sample = last_sample_index;
            }

            if (speech_duration_ms >= min_speech_duration_ms) {
                self.status = .open;
                self.awaiting_close = true;

                return Result{
                    .start_speech = .{
                        .start_sample = self.start_sample.?,
                    },
                };
            }
        },
        .open => {
            // std.debug.print("{any} - {d:.2}\n", .{ self.status, vad });
            if (vad < off_threshold) {
                self.end_sample = last_sample_index;
                self.status = .closing;
            }
        },
        .closing => {
            const threshold_to_reopen = if (self.awaiting_close) off_threshold else on_threshold;

            if (vad >= threshold_to_reopen) {
                // speech resumed
                self.status = if (self.awaiting_close) .open else .opening;
                self.end_sample = null;
                return .{ .ok = .{} };
            }

            // silence since last speech
            const silence_since_speech_samples_f: f32 = @floatFromInt(last_sample_index - self.end_sample.?);
            const samples_per_ms = @as(f32, @floatFromInt(self.in_sample_rate)) / 1000;
            const silence_duration_ms = 1000 * silence_since_speech_samples_f / samples_per_ms;

            if (silence_duration_ms >= max_silence_between_speech_ms) {
                const end_sample = self.end_sample.?;
                self.end_sample = null;
                self.status = .closed;

                if (self.awaiting_close) {
                    self.awaiting_close = false;

                    return Result{
                        .end_speech = .{
                            .end_sample = end_sample,
                        },
                    };
                } else {
                    // intentionally blank, VAD was "opening" but didn't meet the criteria
                }
            }
        },
    }

    return Result{ .ok = .{} };
}

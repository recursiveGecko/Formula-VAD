const std = @import("std");
const Allocator = std.mem.Allocator;
const onnx = @import("onnxruntime");
const SplitSlice = @import("structures/SplitSlice.zig").SplitSlice;
const resample = @import("audio_utils/resample.zig");

const threshold = 0.5;
const min_speech_duration_ms: f32 = 250;
const max_silence_duration_ms: f32 = 100;

// Hard-coded sample rate, this is what the model needs
const model_sample_rate = 16000;
// This is defined in the original repo, the model works best
// with certain sizes of windows.
const window_size_samples: usize = 1024; // 64ms

const Self = @This();

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
    var onnx_instance = try onnx.OnnxInstance.init(allocator, onnx_opts);
    try onnx_instance.initMemoryInfo("Cpu", .arena, 0, .default);
    errdefer onnx_instance.deinit();

    // PCM input
    var pcm_node_dimms: []const i64 = &.{ 1, window_size_samples };
    var pcm = try allocator.alloc(f32, window_size_samples);
    errdefer allocator.free(pcm);
    @memset(pcm, 0);
    var pcm_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        pcm,
        pcm_node_dimms,
        .f32,
    );

    // Sample rate input
    var sr_node_dimms: []const i64 = &.{1};
    var sr: []i64 = try allocator.dupe(i64, &.{ model_sample_rate });
    errdefer allocator.free(sr);
    var sr_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
        i64,
        sr,
        sr_node_dimms,
        .i64,
    );

    // Hidden and cell state inputs
    const size_hc: usize = 2 * 1 * 64;
    var hc_node_dimms: []const i64 = &.{ 2, 1, 64 };

    var h = try allocator.alloc(f32, size_hc);
    errdefer allocator.free(h);
    @memset(h, 0);
    var h_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        h,
        hc_node_dimms,
        .f32,
    );

    var c = try allocator.alloc(f32, size_hc);
    errdefer allocator.free(c);
    @memset(c, 0);
    var c_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
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
    var vad = try allocator.alloc(f32, 1);
    errdefer allocator.free(vad);
    @memset(vad, 0);
    var vad_ort_output = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        vad,
        &.{ 1, 1 },
        .f32,
    );

    var hn = try allocator.alloc(f32, size_hc);
    errdefer allocator.free(hn);
    @memset(hn, 0);
    var hn_ort_output = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        hn,
        hc_node_dimms,
        .f32,
    );

    var cn = try allocator.alloc(f32, size_hc);
    errdefer allocator.free(cn);
    @memset(cn, 0);
    var cn_ort_output = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        cn,
        hc_node_dimms,
        .f32,
    );

    var ort_outputs = try allocator.dupe(?*onnx.c_api.OrtValue, &.{
        vad_ort_output,
        hn_ort_output,
        cn_ort_output,
    });

    onnx_instance.setManagedInputsOutputs(ort_inputs, ort_outputs);

    var self = Self{
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

pub fn runVAD(self: *Self, samples: SplitSlice(f32)) !f32 {
    const downsample_rate = resample.calcDownsampleRate(self.in_sample_rate, model_sample_rate);
    resample.downsampleAudio(samples, self.pcm, downsample_rate);

    try self.onnx_instance.run();

    // Output VAD value
    const vad = self.vad[0];

    // Copy the hidden and cell states for the next iteration
    @memcpy(self.h, self.hn);
    @memcpy(self.c, self.cn);

    return vad;
}

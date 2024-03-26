const std = @import("std");
const Allocator = std.mem.Allocator;
const onnx = @import("onnxruntime");
const resample = @import("audio_utils/resample.zig");

// Hard-coded sample rate, this is what the model needs
const model_sample_rate = 16000;
// This is defined in the original repo, the model works best
// with certain sizes of windows.

// const window_size_samples: usize = 1024; // 64ms
const window_size_samples: usize = 512; // 32ms

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
        .log_level = .@"error",
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

pub fn runVAD(self: *Self, samples: []const f32) !f32 {
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

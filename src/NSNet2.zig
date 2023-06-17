//! Wrapper for NSNet2 denoiser using ONNX Runtime
//!
const std = @import("std");
const pow = std.math.pow;
const Allocator = std.mem.Allocator;
const SplitSlice = @import("./structures/SplitSlice.zig").SplitSlice;
const FFT = @import("./FFT.zig");
const window_fn = @import("audio_utils/window_fn.zig");
const resample = @import("audio_utils/resample.zig");
const onnx = @import("onnxruntime");

const n_fft = 320;
const n_hop = 160;
const chunk_size = 50 * n_hop;

const artifact_mitigation_window = 4;

const Self = @This();

allocator: std.mem.Allocator,
in_sample_rate: usize,
fwd_fft: *FFT,
inv_fft: *FFT,
onnx_instance: *onnx.OnnxInstance,
window: []const f32,
// Temporary buffers
audio_input: []f32,
audio_output: []f32,
specgram: []FFT.Complex,
inv_fft_buffer: []f32,
features: []f32,
gains: []f32,
last_sample: f32 = 0,

pub fn init(
    allocator: std.mem.Allocator,
    sample_rate: usize,
    model_path: [:0]const u8,
) !Self {
    var fwd_fft = try FFT.init(allocator, n_fft, sample_rate, false);
    errdefer fwd_fft.deinit();

    var inv_fft = try FFT.init(allocator, n_fft, sample_rate, true);
    errdefer inv_fft.deinit();

    const window = try createWindow(allocator);
    errdefer allocator.free(window);

    //
    // ONNX Runtime
    //

    const onnx_opts = onnx.OnnxInstanceOpts{
        .log_id = "ZIG",
        .log_level = .warning,
        .model_path = model_path,
        .input_names = &.{"input"},
        .output_names = &.{"output"},
    };
    var onnx_instance = try onnx.OnnxInstance.init(allocator, onnx_opts);
    try onnx_instance.initMemoryInfo("Cpu", .arena, 0, .default);

    // Number of frames per input audio chunk
    const n_frames = calcNFrames(chunk_size);
    // Number of spectrogram bins
    const n_bins = calcNBins();

    //
    // Features input
    //
    const adjusted_n_frames = n_frames + artifact_mitigation_window;
    var features_node_dimms: []const i64 = &.{
        1,
        @intCast(i64, adjusted_n_frames),
        @intCast(i64, n_bins),
    };
    var features = try allocator.alloc(f32, adjusted_n_frames * n_bins);
    errdefer allocator.free(features);
    @memset(features, 0);
    var features_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        features,
        features_node_dimms,
        .f32,
    );
    var ort_inputs = try allocator.dupe(
        *onnx.c_api.OrtValue,
        &.{features_ort_input},
    );

    //
    // Gain output
    //
    var gain_node_dimms: []const i64 = &.{
        1,
        @intCast(i64, adjusted_n_frames),
        @intCast(i64, n_bins),
    };
    var gains = try allocator.alloc(f32, adjusted_n_frames * n_bins);
    errdefer allocator.free(gains);
    var gains_ort_output = try onnx_instance.createTensorWithDataAsOrtValue(
        f32,
        gains,
        gain_node_dimms,
        .f32,
    );
    var ort_outputs = try allocator.dupe(
        ?*onnx.c_api.OrtValue,
        &.{gains_ort_output},
    );

    onnx_instance.setManagedInputsOutputs(ort_inputs, ort_outputs);

    // Allocate extra `n_hop` samples for overlap between chunks
    var audio_input = try allocator.alloc(f32, chunk_size + n_hop);
    @memset(audio_input, 0);

    // Allocate extra `n_hop` samples for overlap between chunks
    var audio_output = try allocator.alloc(f32, chunk_size + n_hop);
    @memset(audio_output, 0);

    var specgram = try allocator.alloc(FFT.Complex, n_frames * n_bins);
    @memset(specgram, FFT.Complex{ .r = 0, .i = 0 });

    var inv_fft_buffer = try allocator.alloc(f32, n_fft);
    @memset(inv_fft_buffer, 0);

    return Self{
        .allocator = allocator,
        .in_sample_rate = sample_rate,
        .window = window,
        .fwd_fft = fwd_fft,
        .inv_fft = inv_fft,
        .onnx_instance = onnx_instance,
        .audio_input = audio_input,
        .audio_output = audio_output,
        .specgram = specgram,
        .inv_fft_buffer = inv_fft_buffer,
        .features = features,
        .gains = gains,
    };
}

pub fn deinit(self: *Self) void {
    self.onnx_instance.deinit();
    self.fwd_fft.deinit();
    self.inv_fft.deinit();
    self.allocator.free(self.window);
    self.allocator.free(self.audio_input);
    self.allocator.free(self.audio_output);
    self.allocator.free(self.specgram);
    self.allocator.free(self.inv_fft_buffer);
    self.allocator.free(self.features);
    self.allocator.free(self.gains);
}

pub fn getChunkSize(in_sample_rate: usize) usize {
    return chunk_size * resample.calcDownsampleRate(in_sample_rate, 16000);
}

pub fn denoise(self: *Self, samples: SplitSlice(f32), denoised_result: []f32) !void {
    const downsample_rate = resample.calcDownsampleRate(self.in_sample_rate, 16000);
    const n_frames = calcNFrames(chunk_size);
    const n_bins = calcNBins();

    const in_len = samples.first.len + samples.second.len;
    if (in_len != chunk_size * downsample_rate) {
        return error.InvalidInputLength;
    }

    //
    // Create logical slices into the input and output buffers
    // for easier access to first and last `n_hop` samples (overlap)
    //
    var in_last_hop: []f32 = self.audio_input[chunk_size .. chunk_size + n_hop];
    var in_first_hop: []f32 = self.audio_input[0..n_hop];
    // This is where the new downsampled audio will be stored, first `n_hop` samples are
    // skipped because they are copied from previous iteration
    var in_read_slice: []f32 = self.audio_input[n_hop..];

    var out_last_hop: []f32 = self.audio_output[chunk_size .. chunk_size + n_hop];
    var out_first_hop: []f32 = self.audio_output[0..n_hop];
    var out_completed_slice: []f32 = self.audio_output[0..chunk_size];
    var out_after_first_hop: []f32 = self.audio_output[n_hop..];

    // Part of the audible artifact mitigation strategy
    // Offset into the features and gains array where the current chunk's data will be stored
    const features_gains_curr_idx = self.features.len - n_frames * n_bins;
    var gains_curr_slice = self.gains[features_gains_curr_idx..];
    var features_curr_slice = self.features[features_gains_curr_idx..];
    var features_copy_src = self.features[n_frames * n_bins ..];
    var features_copy_dst = self.features[0..features_gains_curr_idx];

    // Copy the last n_hop samples from the previous chunk to the beginning
    // of the next chunk for overlap
    @memcpy(in_first_hop, in_last_hop);
    @memcpy(out_first_hop, out_last_hop);

    // We don't need to zero the INput buffer because it's overwritten during downsampling
    // We do need to zero out the OUTput buffer, its values are additive in the final overlap-add step (reconstructAudio fn)
    @memset(out_after_first_hop, 0);

    std.mem.copyBackwards(f32, features_copy_dst, features_copy_src);

    resample.downsampleAudio(
        samples,
        in_read_slice,
        downsample_rate,
    );

    try calcSpectrogram(
        self.fwd_fft,
        self.audio_input,
        n_frames,
        self.window,
        self.specgram,
    );

    calcFeatures(self.specgram, features_curr_slice);
    try self.onnx_instance.run();
    applySpecgramGain(self.specgram, gains_curr_slice);

    try reconstructAudio(
        self.inv_fft,
        self.specgram,
        self.window,
        self.inv_fft_buffer,
        self.audio_output,
    );

    self.last_sample = resample.upsampleAudio(
        out_completed_slice,
        denoised_result,
        self.last_sample,
        downsample_rate,
    );
}

pub fn calcSpectrogram(
    fft: *FFT,
    audio_chunk: []const f32,
    n_frames: usize,
    window: []const f32,
    result_specgram: []FFT.Complex,
) !void {
    const n_bins = calcNBins();

    for (0..n_frames) |frame_idx| {
        const in_start_idx = frame_idx * n_hop;
        const in_end_idx = in_start_idx + n_fft;
        const input_frame = audio_chunk[in_start_idx..in_end_idx];

        const out_start_idx = frame_idx * n_bins;
        const out_end_idx = out_start_idx + n_bins;
        const output_bins = result_specgram[out_start_idx..out_end_idx];

        const in_slice = SplitSlice(f32){
            .first = @constCast(input_frame),
        };

        // Applies the window function, computes the FFT, and stores complex results in output_bins
        try fft.fft(in_slice, window, output_bins);
    }
}

fn calcFeatures(
    specgram: []const FFT.Complex,
    result_features: []f32,
) void {
    if (specgram.len != result_features.len) {
        @panic("specgram and features must have the same length");
    }

    // Original implementation: calcFeat() in featurelib.py (LogPow)
    const p_min = std.math.pow(f32, 10, -12);

    // Calculate Log10 of the power spectrum
    for (0..specgram.len) |i| {
        const bin = specgram[i];

        const pow_spec = pow(f32, bin.r, 2) + pow(f32, bin.i, 2);
        const p_out = @max(pow_spec, p_min);
        const log_p_out = std.math.log(f32, 10, p_out);

        result_features[i] = log_p_out;
    }
}

fn applySpecgramGain(
    specgram: []FFT.Complex,
    gains: []f32,
) void {
    std.debug.assert(specgram.len == gains.len);

    const p_min = -80;
    const p_max = 1;

    for (0..gains.len) |i| {
        var el_gain: f32 = gains[i];

        if (el_gain < p_min) {
            el_gain = p_min;
        } else if (el_gain > p_max) {
            el_gain = p_max;
        }

        specgram[i].r *= el_gain;
        specgram[i].i *= el_gain;
    }
}

fn reconstructAudio(
    fft: *FFT,
    specgram: []FFT.Complex,
    window: []const f32,
    inv_fft_buffer: []f32,
    audio_output: []f32,
) !void {
    const n_bins = calcNBins();
    const n_frames = specgram.len / n_bins;

    // Volume normalization factor
    const vol_norm_factor: f32 = 1 / @intToFloat(f32, n_fft);

    for (0..n_frames) |frame_idx| {
        const in_start_idx = frame_idx * n_bins;
        const in_end_idx = in_start_idx + n_bins;
        const input_bins = specgram[in_start_idx..in_end_idx];

        try fft.invFft(input_bins, inv_fft_buffer);

        const out_start_idx = frame_idx * n_hop;

        for (0..n_fft) |i| {
            inv_fft_buffer[i] *= window[i] * vol_norm_factor;
            audio_output[out_start_idx + i] += inv_fft_buffer[i];
        }
    }
}

/// Original:
/// N_frames = int(np.ceil( (Nx+N_win-N_hop)/N_hop ))
///
/// n_fft (N_win) is always 320 and n_hop (N_hop) is always 160, meaning that
/// (n_fft - n_hop) is always 160. This in turn means that we can simplify the
/// calculation to simple integer division if we ensure that the input length is
/// a multiple of n_hop (160) too.
///
/// Simplification of the calculation done in the original python code.
/// We subtract 1 from the result because we won't be padding the input,
/// instead the last n_hop samples of the previous chunk will be copied to the
/// beginning of the next chunk.
///
/// Consider n_samples = 5, n_fft = 2, and n_hop = 1, with boxes [ ] representing samples:
///
/// Fr\Samp: [C][1][2][3][4][5]
/// #1:       C  x
/// #2:          x  x
/// #3:             x  x
/// #4:                x  x
/// #5:                   x  x
///  C:                      C
/// We can form 5 frames from 5 samples without padding, with C representing the carry-over
/// to the next chunk.
fn calcNFrames(
    n_samples: usize,
) usize {
    if (n_samples % n_hop != 0) {
        @panic("n_samples must be a multiple of n_hop");
    }

    if (n_hop != n_fft / 2) {
        @panic("n_hop must be equal to n_fft / 2");
    }

    return n_samples / n_hop;
}

fn calcNBins() usize {
    return n_fft / 2 + 1;
}

// Original: featurelib.py - calcSpec()
fn createWindow(
    allocator: std.mem.Allocator,
) ![]f32 {
    const window = try allocator.alloc(f32, n_fft);
    errdefer allocator.free(window);

    window_fn.hannWindowSymmetric(window);
    for (0..window.len) |i| {
        window[i] = std.math.sqrt(window[i]);
    }

    return window;
}

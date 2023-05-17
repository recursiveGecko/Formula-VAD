const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const clap = @import("clap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    _ = allocator;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-i, --input <str>      Input file to evaluate.
        \\-r, --reference <str>  Reference file to evaluate against.
        \\
    );
    _ = params;


    // const segments = try parseAudacityTxt(allocator, contents);

    // std.debug.print("{any}", .{segments});
}

pub fn parseAudacityTxt(allocator: Allocator, txt: []const u8) !ArrayList(SpeechSegment) {
    var segments = ArrayList(SpeechSegment).init(allocator);

    const no_cr = try std.mem.replaceOwned(u8, allocator, txt, "\r", "");
    defer allocator.free(no_cr);

    var lines = std.mem.split(u8, txt, "\n");

    while (lines.next()) |line| {
        var fields = std.mem.split(u8, line, "\t");

        var from_str = fields.next() orelse continue;
        var to_str = fields.next() orelse continue;
        // var comment = fields.next() orelse continue;

        var from: f32 = try std.fmt.parseFloat(f32, from_str);
        var to: f32 = try std.fmt.parseFloat(f32, to_str);

        const segment = SpeechSegment{
            .from_sec = from,
            .to_sec = to,
        };

        segments.append(segment);
    }

    return segments;
}

pub const SpeechSegment = struct {
    from_sec: f32,
    to_sec: f32,
};

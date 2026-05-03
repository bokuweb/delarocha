const std = @import("std");
const tokenizer_mod = @import("tokenizer.zig");

const sentences = [_][]const u8{
    "本とカレー",
    "本とカレー本とカレー",
    "本X🍛カレー",
    "カレー本と本とカレー",
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    var tokenizer = try tokenizer_mod.Tokenizer.initRawFiles(
        allocator,
        "../fixtures/lex.csv",
        "../fixtures/matrix.def",
        "../fixtures/char.def",
        "../fixtures/unk.def",
    );
    defer tokenizer.deinit();

    var worker = tokenizer.createWorker(allocator);
    defer worker.deinit();

    var checksum: usize = 0;
    for (0..10_000) |_| {
        for (sentences) |sentence| checksum +%= try worker.tokenizeCount(sentence);
    }

    const start = std.Io.Timestamp.now(io, .boot);
    const iterations: usize = 2_000_000;
    for (0..iterations) |_| {
        for (sentences) |sentence| checksum +%= try worker.tokenizeCount(sentence);
    }
    const elapsed_ns: usize = @intCast(start.durationTo(std.Io.Timestamp.now(io, .boot)).toNanoseconds());
    const total_sentences = iterations * sentences.len;
    const ns_per_sentence = elapsed_ns / total_sentences;

    std.debug.print("delarocha/zig-core-count: {d} ns/sentence (checksum={d})\n", .{
        ns_per_sentence,
        checksum,
    });
}

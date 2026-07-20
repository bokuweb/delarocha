const std = @import("std");
const dict_mod = @import("dictionary.zig");
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

    var unknown_tokenizer = try tokenizer_mod.Tokenizer.initRawFiles(
        allocator,
        "../fixtures/vibrato/lex.csv",
        "../fixtures/vibrato/matrix.def",
        "../fixtures/vibrato/char.def",
        "../fixtures/vibrato/unk.def",
    );
    defer unknown_tokenizer.deinit();
    var unknown_worker = unknown_tokenizer.createWorker(allocator);
    defer unknown_worker.deinit();

    var alpha_dictionary = try dict_mod.Dictionary.fromRawBytes(
        allocator,
        "a,0,0,1,alpha\n",
        "1 1\n0 0 0\n",
        "DEFAULT 0 1 0\nALPHA 1 1 24\n0x0061..0x007A ALPHA\n",
        "DEFAULT,0,0,10000,default\nALPHA,0,0,10000,alpha\n",
    );
    defer alpha_dictionary.deinit();
    var alpha_worker = tokenizer_mod.Worker.init(allocator, &alpha_dictionary, null);
    defer alpha_worker.deinit();

    var ambiguous_dictionary = try dict_mod.Dictionary.fromRawBytes(
        allocator,
        "a,0,0,1,r0\na,0,1,2,r1\na,0,2,3,r2\na,0,3,4,r3\n" ++
            "a,0,4,5,r4\na,0,5,6,r5\na,0,6,7,r6\na,0,7,8,r7\n",
        "8 1\n0 0 0\n1 0 1\n2 0 2\n3 0 3\n4 0 4\n5 0 5\n6 0 6\n7 0 7\n",
        "DEFAULT 0 1 0\n",
        "DEFAULT,0,0,10000,default\n",
    );
    defer ambiguous_dictionary.deinit();
    var ambiguous_worker = tokenizer_mod.Worker.init(allocator, &ambiguous_dictionary, null);
    defer ambiguous_worker.deinit();

    var checksum: usize = 0;
    for (0..10_000) |_| {
        for (sentences) |sentence| checksum +%= try worker.tokenizeCount(sentence);
    }
    var unknown: [2048 * 3]u8 = undefined;
    for (0..2048) |i| @memcpy(unknown[i * 3 ..][0..3], "無");
    var alpha: [2048]u8 = undefined;
    @memset(&alpha, 'a');
    try runSentenceCase(io, &worker, &checksum);
    try runCountCase(io, &unknown_worker, &checksum, "unknown-kanji-32", unknown[0 .. 32 * 3], 20_000);
    try runCountCase(io, &unknown_worker, &checksum, "unknown-kanji-128", unknown[0 .. 128 * 3], 2_000);
    try runCountCase(io, &unknown_worker, &checksum, "unknown-kanji-512", unknown[0 .. 512 * 3], 100);
    try runCountCase(io, &unknown_worker, &checksum, "unknown-kanji-2048", &unknown, 5);
    try runCountCase(io, &alpha_worker, &checksum, "grouped-alpha-32", alpha[0..32], 10_000);
    try runCountCase(io, &alpha_worker, &checksum, "grouped-alpha-128", alpha[0..128], 1_000);
    try runCountCase(io, &alpha_worker, &checksum, "grouped-alpha-512", alpha[0..512], 50);
    try runCountCase(io, &alpha_worker, &checksum, "grouped-alpha-2048", &alpha, 3);
    try runCountCase(io, &ambiguous_worker, &checksum, "ambiguous-a-512", alpha[0..512], 2_000);
}

fn runSentenceCase(io: std.Io, worker: *tokenizer_mod.Worker, checksum: *usize) !void {
    const iterations: usize = 2_000_000;
    const start = std.Io.Timestamp.now(io, .boot);
    for (0..iterations) |_| {
        for (sentences) |sentence| checksum.* +%= try worker.tokenizeCount(sentence);
    }
    const elapsed_ns: usize = @intCast(start.durationTo(std.Io.Timestamp.now(io, .boot)).toNanoseconds());
    const total_sentences = iterations * sentences.len;
    std.debug.print("delarocha/zig-core-count: {d} ns/sentence (checksum={d})\n", .{
        elapsed_ns / total_sentences,
        checksum.*,
    });
}

fn runCountCase(
    io: std.Io,
    worker: *tokenizer_mod.Worker,
    checksum: *usize,
    name: []const u8,
    input: []const u8,
    iterations: usize,
) !void {
    for (0..100) |_| checksum.* +%= try worker.tokenizeCount(input);
    const start = std.Io.Timestamp.now(io, .boot);
    for (0..iterations) |_| checksum.* +%= try worker.tokenizeCount(input);
    const elapsed_ns: usize = @intCast(start.durationTo(std.Io.Timestamp.now(io, .boot)).toNanoseconds());
    const ns_per_input = elapsed_ns / iterations;
    std.debug.print("delarocha/{s}: {d} ns/input ({d} ns/byte, checksum={d})\n", .{
        name,
        ns_per_input,
        ns_per_input / input.len,
        checksum.*,
    });
}

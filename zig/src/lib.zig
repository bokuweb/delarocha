const std = @import("std");

pub const dictionary = @import("dictionary.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const ffi = @import("ffi.zig");

pub const Dictionary = dictionary.Dictionary;
pub const Tokenizer = tokenizer.Tokenizer;
pub const Worker = tokenizer.Worker;
pub const Token = tokenizer.Token;

comptime {
    _ = ffi.delarocha_last_error;
    _ = ffi.delarocha_tokenizer_new;
    _ = ffi.delarocha_tokenizer_new_raw;
    _ = ffi.delarocha_tokenizer_new_raw_count_only;
    _ = ffi.delarocha_tokenizer_new_binary;
    _ = ffi.delarocha_tokenizer_new_binary_bytes;
    _ = ffi.delarocha_tokenizer_new_binary_borrowed_bytes;
    _ = ffi.delarocha_tokenizer_new_binary_borrowed_bytes_count_only;
    _ = ffi.delarocha_tokenizer_new_binary_count_only;
    _ = ffi.delarocha_dictionary_write_binary;
    _ = ffi.delarocha_tokenizer_free;
    _ = ffi.delarocha_worker_new;
    _ = ffi.delarocha_worker_free;
    _ = ffi.delarocha_tokenize;
    _ = ffi.delarocha_tokenize_bytes;
    _ = ffi.delarocha_tokenize_count_bytes;
    _ = ffi.delarocha_tokenize_count_batch;
    _ = ffi.delarocha_token_count;
    _ = ffi.delarocha_token_surface_start;
    _ = ffi.delarocha_token_surface_end;
    _ = ffi.delarocha_token_word_id;
    _ = ffi.delarocha_tokens_copy_spans;
    _ = ffi.delarocha_tokens_copy_metadata;
    _ = ffi.delarocha_token_feature;
}

const minimal_dict =
    "# DELAROCHA_DICT_V1\n" ++
    "matrix\t3\t3\n" ++
    "0\t1\t2\n" ++
    "1\t0\t1\n" ++
    "2\t1\t0\n" ++
    "entry\t本\t1\t1\t10\tnoun,book\n" ++
    "entry\tと\t2\t2\t1\tparticle,and\n" ++
    "entry\tカレー\t1\t1\t10\tnoun,curry\n" ++
    "entry\t本と\t1\t1\t0\tcompound,book-and\n" ++
    "entry\t本とカレー\t1\t1\t50\tcompound,book-and-curry\n";

test "tokenizes with lowest cost path" {
    var dict = try Dictionary.parseMinimal(std.testing.allocator, minimal_dict);
    defer dict.deinit();
    var worker = Worker.init(std.testing.allocator, &dict, null);
    defer worker.deinit();

    const tokens = try worker.tokenize("本とカレー");
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualSlices(u8, "compound,book-and", tokens[0].feature);
    try std.testing.expectEqual(@as(usize, 0), tokens[0].start);
    try std.testing.expectEqual(@as(usize, 6), tokens[0].end);
    try std.testing.expectEqual(@as(usize, 6), tokens[1].start);
    try std.testing.expectEqual(@as(usize, 15), tokens[1].end);
}

test "emits unknown tokens on utf8 boundaries" {
    var dict = try Dictionary.parseMinimal(std.testing.allocator, minimal_dict);
    defer dict.deinit();
    var worker = Worker.init(std.testing.allocator, &dict, null);
    defer worker.deinit();

    const tokens = try worker.tokenize("本X🍛");
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expect(tokens[1].isUnknown());
    try std.testing.expect(tokens[2].isUnknown());
    try std.testing.expectEqual(@as(usize, 3), tokens[1].start);
    try std.testing.expectEqual(@as(usize, 4), tokens[1].end);
    try std.testing.expectEqual(@as(usize, 4), tokens[2].start);
    try std.testing.expectEqual(@as(usize, 8), tokens[2].end);
}

test "worker reuse clears previous tokens" {
    var dict = try Dictionary.parseMinimal(std.testing.allocator, minimal_dict);
    defer dict.deinit();
    var worker = Worker.init(std.testing.allocator, &dict, null);
    defer worker.deinit();

    _ = try worker.tokenize("本とカレー");
    const tokens = try worker.tokenize("カレー");
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqual(@as(u32, 2), tokens[0].word_id);
}

test "builds raw mecab style dictionary" {
    const lex =
        "本,0,0,10,noun,book\n" ++
        "と,0,0,1,particle,and\n" ++
        "カレー,0,0,10,noun,curry\n" ++
        "本と,0,0,0,compound,book-and\n";
    const matrix = "1 1\n0 0 0\n";
    const char_def = "DEFAULT 0 1 0\nALPHA 1 1 0\n0x0041..0x005A ALPHA\n";
    const unk = "DEFAULT,0,0,10000,*\nALPHA,0,0,10,alpha\n";
    var dict = try Dictionary.fromRawBytes(std.testing.allocator, lex, matrix, char_def, unk);
    defer dict.deinit();
    var worker = Worker.init(std.testing.allocator, &dict, null);
    defer worker.deinit();

    const tokens = try worker.tokenize("本ABC");
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(@as(usize, 3), tokens[0].end);
    try std.testing.expectEqual(@as(usize, 3), tokens[1].start);
    try std.testing.expectEqual(@as(usize, 6), tokens[1].end);
    try std.testing.expect(tokens[1].isUnknown());
}

test "cached unknown grouping preserves full and count paths" {
    const lex = "a,0,0,10,system-alpha\n";
    const matrix = "1 1\n0 0 0\n";
    const char_def = "DEFAULT 0 1 0\nALPHA 1 1 24\n0x0061..0x007A ALPHA\n";
    const unk = "DEFAULT,0,0,10000,default\nALPHA,0,0,1,unknown-alpha\n";
    var dict = try Dictionary.fromRawBytes(std.testing.allocator, lex, matrix, char_def, unk);
    defer dict.deinit();
    var worker = Worker.init(std.testing.allocator, &dict, null);
    defer worker.deinit();

    for ([_][]const u8{ "aaaa", "aa", "aaaaaaaa", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) |input| {
        const tokens = try worker.tokenize(input);
        try std.testing.expectEqual(@as(usize, 1), tokens.len);
        try std.testing.expectEqual(@as(usize, 0), tokens[0].start);
        try std.testing.expectEqual(input.len, tokens[0].end);
        try std.testing.expect(tokens[0].isUnknown());
        try std.testing.expectEqual(@as(usize, 1), try worker.tokenizeCount(input));
    }
}

test "roundtrips binary dictionary" {
    const lex =
        "本,0,0,10,noun,book\n" ++
        "と,0,0,1,particle,and\n" ++
        "カレー,0,0,10,noun,curry\n" ++
        "本と,0,0,0,compound,book-and\n";
    const matrix = "1 1\n0 0 0\n";
    const char_def = "DEFAULT 0 1 0\nALPHA 1 1 0\n0x0041..0x005A ALPHA\n";
    const unk = "DEFAULT,0,0,10000,*\nALPHA,0,0,10,alpha\n";
    var raw_dict = try Dictionary.fromRawBytes(std.testing.allocator, lex, matrix, char_def, unk);
    defer raw_dict.deinit();
    const binary = try raw_dict.toBinaryAlloc(std.testing.allocator);
    defer std.testing.allocator.free(binary);
    var binary_dict = try Dictionary.fromBinaryBytes(std.testing.allocator, binary);
    defer binary_dict.deinit();
    var worker = Worker.init(std.testing.allocator, &binary_dict, null);
    defer worker.deinit();

    const tokens = try worker.tokenize("本ABC");
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(@as(usize, 6), tokens[1].end);
    try std.testing.expect(tokens[1].isUnknown());
}

fn expectSameTokens(expected: []const Token, actual: []const Token) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |lhs, rhs| {
        try std.testing.expectEqual(lhs.start, rhs.start);
        try std.testing.expectEqual(lhs.end, rhs.end);
        try std.testing.expectEqual(lhs.word_id, rhs.word_id);
        try std.testing.expectEqualStrings(lhs.feature, rhs.feature);
    }
}

test "binary file loaders (mmap, copy, borrowed, count-only) agree" {
    const allocator = std.testing.allocator;
    // More than 32 entries selects the compact feature table used by large
    // dictionaries; the second lexicon covers the small-dictionary layout.
    var large_lex: std.ArrayList(u8) = .empty;
    defer large_lex.deinit(allocator);
    for (0..40) |index| try large_lex.print(allocator, "語{d},0,0,{d},feature-{d}\n", .{ index, 10 + index % 3, index });
    const small_lex = "本,0,0,10,noun,book\nと,0,0,1,particle,and\nカレー,0,0,10,noun,curry\n本と,0,0,0,compound,book-and\n";
    const matrix = "1 1\n0 0 0\n";
    const char_def = "DEFAULT 0 1 0\nALPHA 1 1 0\n0x0041..0x005A ALPHA\n";
    const unk = "DEFAULT,0,0,10000,*\nALPHA,0,0,10,alpha\n";
    const inputs = [_][]const u8{ "語1語22語39", "本とカレーABC語3", "X🍛", "" };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_][]const u8{ large_lex.items, small_lex }) |lex| {
        var raw_dict = try Dictionary.fromRawBytes(allocator, lex, matrix, char_def, unk);
        defer raw_dict.deinit();
        const binary = try raw_dict.toBinaryAlloc(allocator);
        defer allocator.free(binary);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dict.dic", .data = binary });
        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/dict.dic", .{tmp.sub_path});

        var mapped = try Dictionary.fromBinaryFile(allocator, path);
        defer mapped.deinit();
        try std.testing.expectEqual(dictionary.MappedFile.supported, mapped.mapped_file != null);
        var copied = try Dictionary.fromBinaryFileCopy(allocator, path);
        defer copied.deinit();
        try std.testing.expect(copied.mapped_file == null);
        var borrowed = try Dictionary.fromBorrowedBinaryBytes(allocator, binary);
        defer borrowed.deinit();
        var count_only = try Dictionary.fromBinaryFile(allocator, path);
        defer count_only.deinit();
        count_only.discardFullTokenDataForCount();

        var raw_worker = Worker.init(allocator, &raw_dict, null);
        defer raw_worker.deinit();
        var mapped_worker = Worker.init(allocator, &mapped, null);
        defer mapped_worker.deinit();
        var copied_worker = Worker.init(allocator, &copied, null);
        defer copied_worker.deinit();
        var borrowed_worker = Worker.init(allocator, &borrowed, null);
        defer borrowed_worker.deinit();
        var count_worker = Worker.init(allocator, &count_only, null);
        defer count_worker.deinit();
        for (inputs) |input| {
            const expected = try raw_worker.tokenize(input);
            try expectSameTokens(expected, try mapped_worker.tokenize(input));
            try expectSameTokens(expected, try copied_worker.tokenize(input));
            try expectSameTokens(expected, try borrowed_worker.tokenize(input));
            try std.testing.expectEqual(expected.len, try count_worker.tokenizeCount(input));
        }

        for ([_]usize{ 0, 8, binary.len / 2, binary.len - 1 }) |len| {
            try std.testing.expectError(error.InvalidDictionary, Dictionary.fromBinaryBytes(allocator, binary[0..len]));
            try std.testing.expectError(error.InvalidDictionary, Dictionary.fromBorrowedBinaryBytes(allocator, binary[0..len]));
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dict.dic", .data = binary[0..len] });
            try std.testing.expectError(error.InvalidDictionary, Dictionary.fromBinaryFile(allocator, path));
        }
    }
}

test {
    _ = dictionary;
}

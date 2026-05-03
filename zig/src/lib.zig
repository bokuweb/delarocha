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

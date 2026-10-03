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
    _ = ffi.delarocha_last_error_kind;
    _ = ffi.delarocha_tokenizer_new;
    _ = ffi.delarocha_tokenizer_new_raw;
    _ = ffi.delarocha_tokenizer_new_raw_count_only;
    _ = ffi.delarocha_tokenizer_new_binary;
    _ = ffi.delarocha_tokenizer_new_binary_bytes;
    _ = ffi.delarocha_tokenizer_new_binary_borrowed_bytes;
    _ = ffi.delarocha_tokenizer_new_binary_borrowed_bytes_count_only;
    _ = ffi.delarocha_tokenizer_new_binary_count_only;
    _ = ffi.delarocha_dictionary_write_binary;
    _ = ffi.delarocha_dictionary_write_binary_with_id_order;
    _ = ffi.delarocha_tokenizer_free;
    _ = ffi.delarocha_worker_new;
    _ = ffi.delarocha_worker_free;
    _ = ffi.delarocha_worker_retained_bytes;
    _ = ffi.delarocha_tokenizer_shared_feature_bytes;
    _ = ffi.delarocha_tokenizer_set_shared_feature_limit;
    _ = ffi.delarocha_worker_shrink_to;
    _ = ffi.delarocha_worker_set_retained_limit;
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
    _ = ffi.delarocha_token_size;
    _ = ffi.delarocha_tokenize_tokens;
    _ = ffi.delarocha_worker_resolve_features;
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
    try std.testing.expectEqualSlices(u8, "compound,book-and", tokens[0].feature());
    try std.testing.expectEqual(@as(usize, 0), tokens[0].start);
    try std.testing.expectEqual(@as(usize, 6), tokens[0].end);
    try std.testing.expectEqual(@as(usize, 6), tokens[1].start);
    try std.testing.expectEqual(@as(usize, 15), tokens[1].end);
}

test "token spans stay on utf8 boundaries even with surfaces splitting a character" {
    // 本 is e6 9c ac. Very cheap entries for "\xe6" and "\x9c\xac" would
    // win if a path could pass through byte offset 1, but lattice nodes only
    // begin at character boundaries, so it cannot.
    const bad_dict = minimal_dict ++ "entry\t\xe6\t1\t1\t-30000\tbroken\n" ++ "entry\t\x9c\xac\t1\t1\t-30000\tbroken\n";
    var dict = try Dictionary.parseMinimal(std.testing.allocator, bad_dict);
    defer dict.deinit();
    var worker = Worker.init(std.testing.allocator, &dict, null);
    defer worker.deinit();

    const input = "本X🍛と本カレー";
    for ([_]bool{ false, true }) |deferred| {
        const tokens = if (deferred) try worker.tokenizeDeferred(input) else try worker.tokenize(input);
        var expected_start: usize = 0;
        for (tokens) |token| {
            try std.testing.expectEqual(expected_start, token.start);
            try std.testing.expect(token.end > token.start);
            try std.testing.expect(token.end == input.len or (input[token.end] & 0xc0) != 0x80);
            expected_start = token.end;
        }
        try std.testing.expectEqual(input.len, expected_start);
    }
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

test "final word choice includes the connection cost to end-of-sentence" {
    // Two entries for "b": X is cheaper by word cost (10 < 20) but its right id connects to EOS at +50,
    // while Y's right id connects at 0. MeCab picks Y (total 20 < 60); ignoring EOS would pick X.
    const lex = "b,1,1,10,X\nb,1,2,20,Y\n";
    // "right left cost": BOS (right 0) -> left 1 is free; right 1 -> EOS (left 0) costs 50; right 2 -> EOS is free.
    const matrix = "3 3\n0 0 0\n0 1 0\n0 2 0\n1 0 50\n1 1 0\n1 2 0\n2 0 0\n2 1 0\n2 2 0\n";
    const char_def = "DEFAULT 0 1 0\nALPHA 1 1 0\n0x0041..0x005A ALPHA\n";
    const unk = "DEFAULT,0,0,10000,*\nALPHA,0,0,10000,alpha\n";
    var dict = try Dictionary.fromRawBytes(std.testing.allocator, lex, matrix, char_def, unk);
    defer dict.deinit();
    var worker = Worker.init(std.testing.allocator, &dict, null);
    defer worker.deinit();

    const tokens = try worker.tokenize("b");
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqualStrings("Y", tokens[0].feature());
    // the count-only path must agree
    try std.testing.expectEqual(@as(usize, 1), try worker.tokenizeCount("b"));
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
        try std.testing.expectEqualStrings(lhs.feature(), rhs.feature());
    }
}

test "binary file loaders (mmap, copy, borrowed, count-only) agree" {
    const allocator = std.testing.allocator;
    // More than 32 entries selects the compact feature table used by large
    // dictionaries; the second lexicon covers the small-dictionary layout.
    var large_lex: std.ArrayList(u8) = .empty;
    defer large_lex.deinit(allocator);
    for (0..40) |index| try large_lex.print(allocator, "語{d},0,0,{d},feature-{d}\n", .{ index, 10 + index % 3, index });
    // MeCab-style features select the compact feature encoding.
    var compact_lex: std.ArrayList(u8) = .empty;
    defer compact_lex.deinit(allocator);
    for (0..40) |index| {
        try compact_lex.print(allocator, "語{d},0,0,{d},名詞,一般,*,*,*,*,語{d},ゴ{d},ゴ{d}\n", .{ index, 10 + index % 3, index, index, index });
        try compact_lex.print(allocator, "ご{d},0,0,{d},動詞,自立,*,*,五段・ラ行,基本形,ご{d}る,ゴ{d},ゴー{d}\n", .{ index, 12 + index % 5, index, index, index });
    }
    const small_lex = "本,0,0,10,noun,book\nと,0,0,1,particle,and\nカレー,0,0,10,noun,curry\n本と,0,0,0,compound,book-and\n";
    const matrix = "1 1\n0 0 0\n";
    const char_def = "DEFAULT 0 1 0\nALPHA 1 1 0\n0x0041..0x005A ALPHA\n";
    const unk = "DEFAULT,0,0,10000,*\nALPHA,0,0,10,alpha\n";
    const inputs = [_][]const u8{ "語1語22語39", "本とカレーABC語3", "X🍛", "", "ご1ご22語7ご39XYZ" };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Case = struct { lex: []const u8, compact: bool, options: dictionary.BinaryOptions = .{} };
    const cases = [_]Case{
        .{ .lex = large_lex.items, .compact = false },
        .{ .lex = small_lex, .compact = false },
        .{ .lex = compact_lex.items, .compact = true },
        .{ .lex = compact_lex.items, .compact = false, .options = .{ .compact_features = false } },
    };
    for (cases) |case| {
        const lex = case.lex;
        var raw_dict = try Dictionary.fromRawBytes(allocator, lex, matrix, char_def, unk);
        defer raw_dict.deinit();
        const binary = try raw_dict.toBinaryAllocWithOptions(allocator, case.options);
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
        try std.testing.expectEqual(case.compact, mapped.features_compact);
        try std.testing.expectEqual(case.compact, copied.features_compact);
        try std.testing.expectEqual(case.compact, borrowed.features_compact);
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
            // Deferred features resolve to the same bytes after the input
            // buffer is gone.
            const scratch = try allocator.dupe(u8, input);
            const deferred = try mapped_worker.tokenizeDeferred(scratch);
            @memset(scratch, 0);
            allocator.free(scratch);
            try mapped_worker.resolveFeatures();
            try mapped_worker.resolveFeatures();
            try expectSameTokens(expected, deferred);
        }

        for ([_]usize{ 0, 8, binary.len / 2, binary.len - 1 }) |len| {
            try std.testing.expectError(error.InvalidDictionary, Dictionary.fromBinaryBytes(allocator, binary[0..len]));
            try std.testing.expectError(error.InvalidDictionary, Dictionary.fromBorrowedBinaryBytes(allocator, binary[0..len]));
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dict.dic", .data = binary[0..len] });
            try std.testing.expectError(error.InvalidDictionary, Dictionary.fromBinaryFile(allocator, path));
        }

        // Files written by earlier format versions are rejected up front
        // instead of being misread with the current layout.
        const legacy = try allocator.dupe(u8, binary);
        defer allocator.free(legacy);
        for ([_][]const u8{ "DLRDIC01", "DLRDIC02", "DLRDIC03" }) |magic| {
            @memcpy(legacy[0..magic.len], magic);
            try std.testing.expectError(error.UnsupportedDictionaryVersion, Dictionary.fromBinaryBytes(allocator, legacy));
            try std.testing.expectError(error.UnsupportedDictionaryVersion, Dictionary.fromBorrowedBinaryBytes(allocator, legacy));
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dict.dic", .data = legacy });
            try std.testing.expectError(error.UnsupportedDictionaryVersion, Dictionary.fromBinaryFile(allocator, path));
        }
    }
}

test "raw lexicon entries share one string blob and keep verbatim features" {
    const allocator = std.testing.allocator;
    const lex = "本,0,0,10,noun,book,*\r\n\n  と,0,0,1\nカレー,0,0,10,,\n";
    // The matrix must hold IPADIC's connection id 5 for the U+2015
    // compatibility entry to be added.
    const matrix_6x6 = "6 6\n0 0 0\n";
    var dict = try Dictionary.fromRawBytes(allocator, lex, matrix_6x6, "DEFAULT 0 1 0\n", "DEFAULT,0,0,10000,*\n");
    defer dict.deinit();
    // Three lexicon rows plus the U+2015 compatibility entry.
    try std.testing.expectEqual(@as(usize, 4), dict.entries.len);
    const expected = [_][2][]const u8{
        .{ "本", "noun,book,*" },
        .{ "と", "" },
        .{ "カレー", "," },
        .{ "―", "記号,一般,*,*,*,*,―,―,―" },
    };
    const blob_start = @intFromPtr(dict.entry_blob.ptr);
    for (dict.entries, expected) |entry, want| {
        try std.testing.expectEqualStrings(want[0], entry.surface);
        try std.testing.expectEqualStrings(want[1], entry.feature);
        for ([_][]const u8{ entry.surface, entry.feature }) |text| {
            try std.testing.expect(@intFromPtr(text.ptr) >= blob_start);
            try std.testing.expect(@intFromPtr(text.ptr) + text.len <= blob_start + dict.entry_blob.len);
        }
    }
    try std.testing.expectError(error.InvalidDictionary, Dictionary.fromRawBytes(allocator, "本,0,0\n", "1 1\n0 0 0\n", "DEFAULT 0 1 0\n", "DEFAULT,0,0,10000,*\n"));
    try std.testing.expectError(error.InvalidCharacter, Dictionary.fromRawBytes(allocator, "本,0,x,1,f\n", "1 1\n0 0 0\n", "DEFAULT 0 1 0\n", "DEFAULT,0,0,10000,*\n"));

    var count_only = try Dictionary.fromRawBytes(allocator, lex, matrix_6x6, "DEFAULT 0 1 0\n", "DEFAULT,0,0,10000,*\n");
    defer count_only.deinit();
    count_only.discardFullTokenDataForCount();
}

test "worker shrink and retained-capacity limit keep results identical" {
    const allocator = std.testing.allocator;
    var dict = try Dictionary.parseMinimal(allocator, minimal_dict);
    defer dict.deinit();

    var long_input: std.ArrayList(u8) = .empty;
    defer long_input.deinit(allocator);
    for (0..512) |_| try long_input.appendSlice(allocator, "本とカレーX🍛");
    const inputs = [_][]const u8{ long_input.items, "本とカレー", "本X🍛", "", long_input.items[0..60] };

    var reference = Worker.init(allocator, &dict, null);
    defer reference.deinit();
    var shrinking = Worker.init(allocator, &dict, null);
    defer shrinking.deinit();
    var capped = Worker.init(allocator, &dict, null);
    defer capped.deinit();
    const limit: usize = 4096;
    capped.setRetainedCapacityLimit(limit);

    for (0..2) |_| {
        for (inputs) |input| {
            const expected_count = try reference.tokenizeCount(input);
            const expected = try reference.tokenize(input);

            try expectSameTokens(expected, try shrinking.tokenize(input));
            try std.testing.expectEqual(expected_count, try shrinking.tokenizeCount(input));
            try std.testing.expect(shrinking.retainedBytes() > 0 or input.len == 0);
            shrinking.shrinkTo(limit);
            try std.testing.expect(shrinking.retainedBytes() <= limit);
            try std.testing.expectEqual(expected_count, try shrinking.tokenizeCount(input));
            try expectSameTokens(expected, try shrinking.tokenize(input));
            shrinking.shrink();
            try std.testing.expectEqual(@as(usize, 0), shrinking.retainedBytes());

            const capped_tokens = try capped.tokenize(input);
            try expectSameTokens(expected, capped_tokens);
            // Only the returned token buffer may exceed the cap, and only by
            // what the result itself needs.
            try std.testing.expect(capped.retainedBytes() <= @max(limit, capped_tokens.len * @sizeOf(Token)));
            try std.testing.expectEqual(expected_count, try capped.tokenizeCount(input));
        }
    }
    // Small inputs stay below the cap and keep their buffers for reuse.
    _ = try capped.tokenize("本とカレー");
    _ = try capped.tokenizeCount("本とカレー");
    try std.testing.expect(capped.retainedBytes() > 0);
    try std.testing.expect(capped.retainedBytes() <= limit);
}

test "connection-id renumbering preserves tokenization" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const random = prng.random();
    const id_count = 7;
    const surfaces = [_][]const u8{ "a", "b", "ab", "ba", "本", "と", "本と", "カレー", "レー", "aab", "bb" };
    var lex: std.ArrayList(u8) = .empty;
    defer lex.deinit(allocator);
    for (0..60) |index| {
        try lex.print(allocator, "{s},{d},{d},{d},f{d}\n", .{
            surfaces[index % surfaces.len],
            random.uintLessThan(u16, id_count),
            random.uintLessThan(u16, id_count),
            random.intRangeAtMost(i32, -200, 800),
            index,
        });
    }
    var matrix: std.ArrayList(u8) = .empty;
    defer matrix.deinit(allocator);
    try matrix.print(allocator, "{d} {d}\n", .{ id_count, id_count });
    for (0..id_count) |right| for (0..id_count) |left| {
        try matrix.print(allocator, "{d} {d} {d}\n", .{ right, left, random.intRangeAtMost(i16, -300, 300) });
    };
    const char_def = "DEFAULT 0 1 0\nALPHA 1 1 3\nKANJI 0 0 2\n0x0061..0x007A ALPHA\n0x4E00..0x9FFF KANJI\n";
    const unk = "DEFAULT,3,4,900,default\nALPHA,5,6,300,alpha\nALPHA,6,5,320,alpha2\nKANJI,2,3,500,kanji\n";
    const inputs = [_][]const u8{ "abba本とカレーxyz", "本本とと", "baab", "カレーレー漢字", "zzz🍛ab", "", "a" };

    var original = try Dictionary.fromRawBytes(allocator, lex.items, matrix.items, char_def, unk);
    defer original.deinit();
    var original_worker = Worker.init(allocator, &original, null);
    defer original_worker.deinit();

    for (0..3) |variant| {
        var renumbered = try Dictionary.fromRawBytes(allocator, lex.items, matrix.items, char_def, unk);
        defer renumbered.deinit();
        const weights = switch (variant) {
            0 => try renumbered.connectionIdPriorWeights(allocator),
            1 => try tokenizer.sampleConnectionIdWeights(allocator, &renumbered, "abba本と\nカレー漢字ab\n"),
            else => try dictionary.ConnectionIdWeights.parse(allocator, id_count, id_count, "1 1 7\n2 5 0\n# comment\n6 9 2\n"),
        };
        defer weights.deinit(allocator);
        try renumbered.renumberConnectionIds(weights);

        const binary = try renumbered.toBinaryAlloc(allocator);
        defer allocator.free(binary);
        var loaded = try Dictionary.fromBinaryBytes(allocator, binary);
        defer loaded.deinit();

        var renumbered_worker = Worker.init(allocator, &renumbered, null);
        defer renumbered_worker.deinit();
        var loaded_worker = Worker.init(allocator, &loaded, null);
        defer loaded_worker.deinit();
        for (inputs) |input| {
            const expected = try original_worker.tokenize(input);
            for ([_]*Worker{ &renumbered_worker, &loaded_worker }) |worker| {
                const actual = try worker.tokenize(input);
                try expectSameTokens(expected, actual);
                for (expected, actual) |lhs, rhs| try std.testing.expectEqual(lhs.total_cost, rhs.total_cost);
                try std.testing.expectEqual(try original_worker.tokenizeCount(input), try worker.tokenizeCount(input));
            }
        }
    }
}

// Characters of the generated three-character surfaces: hiragana (whose
// katakana rendering the compact encoding references), katakana and kanji.
const generated_chars = [_][]const u8{
    "あ",
    "い",
    "う",
    "え",
    "お",
    "か",
    "き",
    "く",
    "け",
    "こ",
    "さ",
    "し",
    "す",
    "せ",
    "そ",
    "た",
    "ち",
    "つ",
    "て",
    "と",
    "な",
    "に",
    "ぬ",
    "ね",
    "の",
    "は",
    "ひ",
    "ふ",
    "ア",
    "イ",
    "ウ",
    "エ",
    "オ",
    "本",
    "語",
    "猫",
    "犬",
    "山",
    "川",
    "空",
};

const GeneratedLexicon = struct {
    lex: []u8,
    // Per entry (= word id): surface and expected feature bytes.
    surfaces: [][]u8,
    features: [][]u8,

    fn deinit(self: GeneratedLexicon, allocator: std.mem.Allocator) void {
        for (self.surfaces, self.features) |surface, feature| {
            allocator.free(surface);
            allocator.free(feature);
        }
        allocator.free(self.surfaces);
        allocator.free(self.features);
        allocator.free(self.lex);
    }
};

fn appendKatakana(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |code| {
        const mapped: u21 = if (code >= 0x3041 and code <= 0x3096) code + 0x60 else code;
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(mapped, &buf);
        try out.appendSlice(allocator, buf[0..len]);
    }
}

/// `count` entries with distinct three-character surfaces, so a
/// concatenation of surfaces tokenizes into exactly those entries, and
/// MeCab-style features of several shapes (surface, katakana and column
/// references, long literals, short raw-fallback rows, one invalid UTF-8
/// literal) that select the compact feature encoding.
fn generatedLexicon(allocator: std.mem.Allocator, count: usize) !GeneratedLexicon {
    const n = generated_chars.len;
    std.debug.assert(count <= n * n * n);
    var lex: std.ArrayList(u8) = .empty;
    errdefer lex.deinit(allocator);
    const surfaces = try allocator.alloc([]u8, count);
    errdefer allocator.free(surfaces);
    const features = try allocator.alloc([]u8, count);
    errdefer allocator.free(features);
    for (0..count) |i| {
        const surface = try std.mem.concat(allocator, u8, &.{ generated_chars[i % n], generated_chars[(i / n) % n], generated_chars[i / (n * n)] });
        var kana: std.ArrayList(u8) = .empty;
        defer kana.deinit(allocator);
        try appendKatakana(allocator, &kana, surface);
        var feature: std.ArrayList(u8) = .empty;
        defer feature.deinit(allocator);
        switch (i % 6) {
            0 => try feature.print(allocator, "名詞,一般,*,*,*,*,{s},{s},{s}", .{ surface, kana.items, kana.items }),
            1 => try feature.print(allocator, "動詞,自立,*,*,五段・ラ行,基本形,{s}る,{s},{s}ー", .{ surface, kana.items, kana.items }),
            2 => try feature.print(allocator, "名詞,固有名詞,人名,姓,*,*,{s},{s}{d},{s}{d}", .{ surface, kana.items, i, kana.items, i }),
            3 => try feature.print(allocator, "記号,{d}", .{i}),
            4 => try feature.print(allocator, "副詞,一般,*,*,*,*,{s},{s},{s},長い説明文その{d}は特徴列の長さを稼ぐためのものです", .{ surface, kana.items, kana.items, i }),
            else => try feature.print(allocator, "名詞,サ変接続,*,*,*,*,{s},{s},{s}", .{ surface[0..3], kana.items, kana.items[3..] }),
        }
        // One entry carries invalid UTF-8; its decoded bytes are still
        // pinned exactly.
        if (i == 7) try feature.appendSlice(allocator, "\xff");
        try lex.print(allocator, "{s},0,0,{d},{s}\n", .{ surface, 10 + i % 7, feature.items });
        surfaces[i] = surface;
        features[i] = try feature.toOwnedSlice(allocator);
    }
    return .{ .lex = try lex.toOwnedSlice(allocator), .surfaces = surfaces, .features = features };
}

const generated_matrix = "1 1\n0 0 0\n";
const generated_char_def = "DEFAULT 0 1 0\nALPHA 1 1 0\n0x0041..0x005A ALPHA\n";
const generated_unk = "DEFAULT,0,0,30000,*\nALPHA,0,0,10,alpha\n";

/// Lines over the generated entries: runs of consecutive entries, the same
/// entry repeated, a strided sweep over every entry, and unknown words.
fn generatedInputs(allocator: std.mem.Allocator, lexicon: GeneratedLexicon) !std.ArrayList([]u8) {
    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    const count = lexicon.surfaces.len;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    var start: usize = 0;
    while (start < count) {
        const len = @min(1 + random.uintLessThan(usize, 40), count - start);
        for (lexicon.surfaces[start..][0..len]) |surface| try line.appendSlice(allocator, surface);
        if (len % 5 == 0) try line.appendSlice(allocator, "ABC");
        try lines.append(allocator, try line.toOwnedSlice(allocator));
        start += len;
    }
    for (0..200) |_| try line.appendSlice(allocator, lexicon.surfaces[3 % count]);
    try lines.append(allocator, try line.toOwnedSlice(allocator));
    var index: usize = 0;
    for (0..count) |_| {
        try line.appendSlice(allocator, lexicon.surfaces[index]);
        index = (index + 7919) % count;
        if (line.items.len > 300) try lines.append(allocator, try line.toOwnedSlice(allocator));
    }
    try lines.append(allocator, try line.toOwnedSlice(allocator));
    try lines.append(allocator, try allocator.dupe(u8, ""));
    return lines;
}

/// Every token's feature equals the generated feature of its word id (or the
/// unknown-word feature), and tokens are contiguous.
fn expectGeneratedFeatures(lexicon: GeneratedLexicon, input: []const u8, tokens: []const Token) !void {
    var end: usize = 0;
    for (tokens) |token| {
        try std.testing.expectEqual(end, token.start);
        end = token.end;
        if (token.isUnknown()) {
            try std.testing.expectEqualStrings("alpha", token.feature());
            continue;
        }
        try std.testing.expectEqualStrings(lexicon.surfaces[token.word_id], input[token.start..token.end]);
        try std.testing.expectEqualStrings(lexicon.features[token.word_id], token.feature());
    }
    try std.testing.expectEqual(input.len, end);
}

test "compact features decode byte-identically under decode cache pressure" {
    const allocator = std.testing.allocator;
    const lexicon = try generatedLexicon(allocator, 3000);
    defer lexicon.deinit(allocator);
    var lines = try generatedInputs(allocator, lexicon);
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    var raw_dict = try Dictionary.fromRawBytes(allocator, lexicon.lex, generated_matrix, generated_char_def, generated_unk);
    defer raw_dict.deinit();
    const binary = try raw_dict.toBinaryAlloc(allocator);
    defer allocator.free(binary);
    var dict = try Dictionary.fromBinaryBytes(allocator, binary);
    defer dict.deinit();
    try std.testing.expect(dict.features_compact);

    // Every entry, through the raw dictionary and the compact one.
    var raw_worker = Worker.init(allocator, &raw_dict, null);
    defer raw_worker.deinit();
    var fresh = Worker.init(allocator, &dict, null);
    defer fresh.deinit();
    var distinct = try std.DynamicBitSet.initEmpty(allocator, lexicon.surfaces.len);
    defer distinct.deinit();
    var distinct_bytes: usize = 0;
    var known_tokens: usize = 0;
    for (lines.items) |line| {
        const expected = try raw_worker.tokenize(line);
        try expectGeneratedFeatures(lexicon, line, expected);
        const tokens = try fresh.tokenize(line);
        try expectSameTokens(expected, tokens);
        for (tokens) |token| if (!token.isUnknown()) {
            known_tokens += 1;
            if (!distinct.isSet(token.word_id)) {
                distinct.set(token.word_id);
                distinct_bytes += token.feature_len;
            }
        };
    }
    try std.testing.expectEqual(lexicon.surfaces.len, distinct.count());
    // With the default limit every word is decoded once.
    const unlimited = fresh.featureStats();
    try std.testing.expectEqual(@as(u64, 0), unlimited.restarts);
    try std.testing.expectEqual(@as(u64, known_tokens), unlimited.hits + unlimited.misses);

    // Tiny and moderate cache limits force restarts; eager, deferred,
    // shrinking and capped workers interleave on the same dictionary and
    // keep producing the same bytes.
    for ([_]usize{ 0, 64, 4096 }) |byte_limit| {
        var eager = Worker.init(allocator, &dict, null);
        defer eager.deinit();
        eager.setFeatureCacheByteLimit(byte_limit);
        var deferred = Worker.init(allocator, &dict, null);
        defer deferred.deinit();
        deferred.setFeatureCacheByteLimit(byte_limit);
        var capped = Worker.init(allocator, &dict, null);
        defer capped.deinit();
        capped.setFeatureCacheByteLimit(byte_limit);
        capped.setRetainedCapacityLimit(2048);
        var shrinking = Worker.init(allocator, &dict, null);
        defer shrinking.deinit();
        shrinking.setFeatureCacheByteLimit(byte_limit);
        for (0..2) |pass| {
            for (lines.items, 0..) |line, index| {
                const expected = try raw_worker.tokenize(line);
                try expectSameTokens(expected, try eager.tokenize(line));

                const scratch = try allocator.dupe(u8, line);
                _ = try deferred.tokenizeDeferred(scratch);
                @memset(scratch, 0);
                allocator.free(scratch);
                try deferred.resolveFeatures();
                try expectSameTokens(expected, deferred.tokens.items);

                try expectSameTokens(expected, try capped.tokenize(line));
                _ = try capped.tokenizeDeferred(line);
                try capped.resolveFeatures();
                try expectSameTokens(expected, capped.tokens.items);

                _ = try shrinking.tokenize(line);
                if ((index + pass) % 3 == 0) shrinking.shrink() else shrinking.shrinkTo(index * 97 % 8192);
                try expectSameTokens(expected, try shrinking.tokenize(line));
            }
        }
        const stats = eager.featureStats();
        try std.testing.expect(stats.restarts > 0);
        try std.testing.expect(stats.decoded_bytes > distinct_bytes);
        try std.testing.expect(deferred.featureStats().restarts > 0);
    }
}

fn expectGeneratedLines(worker: *Worker, raw_worker: *Worker, lines: []const []u8) !void {
    for (lines) |line| try expectSameTokens(try raw_worker.tokenize(line), try worker.tokenize(line));
}

const SharedThreadContext = struct {
    tokenizer: *Tokenizer,
    lexicon: *const GeneratedLexicon,
    lines: []const []u8,
    offset: usize,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *SharedThreadContext) void {
        self.runChecked() catch self.failed.store(true, .release);
    }

    fn runChecked(self: *SharedThreadContext) !void {
        var worker = self.tokenizer.createWorker(std.testing.allocator);
        defer worker.deinit();
        for (0..self.lines.len) |step| {
            const line = self.lines[(step + self.offset) % self.lines.len];
            if (step % 2 == 0) {
                try expectGeneratedFeatures(self.lexicon.*, line, try worker.tokenize(line));
            } else {
                _ = try worker.tokenizeDeferred(line);
                try worker.resolveFeatures();
                try expectGeneratedFeatures(self.lexicon.*, line, worker.tokens.items);
            }
        }
    }
};

test "tokenizer workers share decoded compact features" {
    const allocator = std.testing.allocator;
    // About 330 KB of decoded features: more than one shared arena chunk.
    const lexicon = try generatedLexicon(allocator, 5000);
    defer lexicon.deinit(allocator);
    var lines = try generatedInputs(allocator, lexicon);
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    var raw_dict = try Dictionary.fromRawBytes(allocator, lexicon.lex, generated_matrix, generated_char_def, generated_unk);
    defer raw_dict.deinit();
    const binary = try raw_dict.toBinaryAlloc(allocator);
    defer allocator.free(binary);
    var raw_worker = Worker.init(allocator, &raw_dict, null);
    defer raw_worker.deinit();

    const chunk_size = tokenizer.SharedFeatures.chunk_size;
    for ([_]usize{ tokenizer.SharedFeatures.default_byte_limit, 0, chunk_size }) |shared_limit| {
        var tok: Tokenizer = .{ .allocator = allocator, .dictionary = try Dictionary.fromBinaryBytes(allocator, binary) };
        defer tok.deinit();
        try std.testing.expect(tok.dictionary.features_compact);
        tok.setSharedFeatureLimit(shared_limit);

        // The first worker decodes; with sharing, later workers find every
        // feature already decoded.
        var first = tok.createWorker(allocator);
        defer first.deinit();
        first.setFeatureCacheByteLimit(64);
        try expectGeneratedLines(&first, &raw_worker, lines.items);
        var second = tok.createWorker(allocator);
        defer second.deinit();
        second.setFeatureCacheByteLimit(64);
        var deferred = tok.createWorker(allocator);
        defer deferred.deinit();
        var capped = tok.createWorker(allocator);
        defer capped.deinit();
        capped.setRetainedCapacityLimit(2048);
        var shrinking = tok.createWorker(allocator);
        defer shrinking.deinit();
        for (0..2) |pass| {
            for (lines.items, 0..) |line, index| {
                const expected = try raw_worker.tokenize(line);
                try expectSameTokens(expected, try second.tokenize(line));
                const scratch = try allocator.dupe(u8, line);
                _ = try deferred.tokenizeDeferred(scratch);
                @memset(scratch, 0);
                allocator.free(scratch);
                try deferred.resolveFeatures();
                try expectSameTokens(expected, deferred.tokens.items);
                try expectSameTokens(expected, try capped.tokenize(line));
                _ = try capped.tokenizeDeferred(line);
                try capped.resolveFeatures();
                try expectSameTokens(expected, capped.tokens.items);
                _ = try shrinking.tokenize(line);
                if ((index + pass) % 3 == 0) shrinking.shrink() else shrinking.shrinkTo(index * 97 % 8192);
                try expectSameTokens(expected, try shrinking.tokenize(line));
            }
        }

        const shared_bytes = tok.sharedFeatureBytes();
        const first_stats = first.featureStats();
        const second_stats = second.featureStats();
        if (shared_limit == tokenizer.SharedFeatures.default_byte_limit) {
            try std.testing.expect(!tok.shared_features.full.load(.acquire));
            try std.testing.expect(shared_bytes > 0);
            try std.testing.expect(first_stats.decoded_bytes > 0);
            try std.testing.expectEqual(@as(u64, 0), first_stats.restarts);
            try std.testing.expectEqual(@as(u64, 0), second_stats.decoded_bytes);
            try std.testing.expectEqual(@as(u64, 0), deferred.featureStats().decoded_bytes);
        } else {
            // Without room for every word, the rest go to the bounded
            // worker caches, which restart.
            try std.testing.expect(tok.shared_features.full.load(.acquire));
            try std.testing.expect(tok.shared_features.arena_bytes <= shared_limit);
            try std.testing.expectEqual(shared_limit == 0, shared_bytes == 0);
            try std.testing.expect(first_stats.restarts > 0);
            try std.testing.expect(second_stats.restarts > 0);
            try std.testing.expect(second_stats.decoded_bytes > 0);
        }

        // Workers on several threads decode and share concurrently.
        var threaded: Tokenizer = .{ .allocator = allocator, .dictionary = try Dictionary.fromBinaryBytes(allocator, binary) };
        defer threaded.deinit();
        threaded.setSharedFeatureLimit(shared_limit);
        var contexts: [4]SharedThreadContext = undefined;
        var threads: [4]std.Thread = undefined;
        for (&contexts, &threads, 0..) |*context, *thread, index| {
            context.* = .{ .tokenizer = &threaded, .lexicon = &lexicon, .lines = lines.items, .offset = index * lines.items.len / 4 };
            thread.* = try std.Thread.spawn(.{}, SharedThreadContext.run, .{context});
        }
        for (threads) |thread| thread.join();
        for (contexts) |context| try std.testing.expect(!context.failed.load(.acquire));
    }
}

test {
    _ = dictionary;
    _ = dictionary.feature_codec;
}

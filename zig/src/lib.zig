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

test {
    _ = dictionary;
    _ = dictionary.feature_codec;
}

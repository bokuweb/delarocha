//! Compact encoding for dictionary entry features.
//!
//! MeCab-style features are CSV rows whose leading columns (part of speech,
//! conjugation type/form) take only a few hundred distinct combinations, while
//! the trailing columns often repeat the surface (base form), a katakana
//! rendering of it (reading), or an earlier column (pronunciation == reading).
//! The encoder stores, per entry:
//!
//!   varint head
//!     head == 0: the raw feature bytes follow (per-entry fallback)
//!     head >= 1: prefix table entry `head - 1` (the first `prefix_fields`
//!                columns), then one op per remaining column until the end
//!                of the record
//!
//! Each op emits `,` (unless it is the very first column) followed by
//! `reference[0..n] ++ literal`:
//!
//!   tag byte: bits 7..5 reference (0 none, 1 surface, 2 katakana(surface),
//!                                  3.. column 1..5 back within the ops)
//!             bit 4     explicit copy length `n` (varint) follows;
//!                       otherwise the whole reference is copied
//!             bits 3..0 literal length, 15 = 15 + varint
//!   [varint n] [varint literal length extension] literal bytes
//!
//! Decoding needs the entry surface, which for a known word is exactly the
//! matched input bytes. The decoder validates every length against the record
//! and rejects copies that would split a UTF-8 sequence of the reference, so
//! for valid UTF-8 input the validity of a decoded feature depends only on the
//! dictionary bytes of that entry (see `decode`).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Upper bound for one op-decoded feature. Longer features are stored raw.
pub const max_decoded_len: usize = 1 << 16;
/// Columns an op can refer back to.
const max_back_refs = 5;
const ref_none: u8 = 0;
const ref_surface: u8 = 1;
const ref_katakana: u8 = 2;
const ref_first_column: u8 = 3;
const explicit_len_bit: u8 = 0x10;
const inline_literal_limit: usize = 15;
/// Prefix column counts considered by the encoder.
const max_prefix_fields: u32 = 16;

/// Runtime view of the prefix table. Entry `i` is
/// `blob[offsets[i]..offsets[i + 1]]`; both slices may be borrowed from a
/// memory-mapped dictionary.
pub const Table = struct {
    prefix_fields: u32 = 0,
    offsets: []align(1) const u32 = &.{},
    blob: []const u8 = &.{},

    pub fn count(self: Table) usize {
        return if (self.offsets.len == 0) 0 else self.offsets.len - 1;
    }

    inline fn prefix(self: Table, index: usize) ?[]const u8 {
        if (index + 1 >= self.offsets.len) return null;
        const start: usize = self.offsets[index];
        const end: usize = self.offsets[index + 1];
        if (start > end or end > self.blob.len) return null;
        return self.blob[start..end];
    }
};

pub const Decoded = union(enum) {
    /// The feature is a slice of the record (raw fallback) or empty when the
    /// record is corrupt.
    borrowed: []const u8,
    /// The feature was appended to the output buffer with this length.
    appended: usize,
};

inline fn readVarint(bytes: []const u8, cursor: *usize) ?usize {
    // At most four bytes (28 bits): every length fits a u32 blob offset.
    var value: u32 = 0;
    var shift: u5 = 0;
    while (cursor.* < bytes.len) {
        const byte = bytes[cursor.*];
        cursor.* += 1;
        value |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        if (shift == 21) return null;
        shift += 7;
    }
    return null;
}

inline fn isContinuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

/// Whether copying `len` bytes of `reference` keeps whole UTF-8 sequences.
inline fn isCopyBoundary(reference: []const u8, len: usize) bool {
    return len == reference.len or !isContinuation(reference[len]);
}

/// Appends `source` with hiragana (U+3041..U+3096) mapped to katakana. Both
/// ranges are three-byte UTF-8 sequences, so lengths are preserved.
fn appendKatakana(out: []u8, source: []const u8) void {
    var i: usize = 0;
    while (i < source.len) {
        const byte = source[i];
        if (byte == 0xe3 and i + 3 <= source.len) {
            const code = (@as(u21, byte & 0x0f) << 12) | (@as(u21, source[i + 1] & 0x3f) << 6) | (source[i + 2] & 0x3f);
            if (code >= 0x3041 and code <= 0x3096 and isContinuation(source[i + 1]) and isContinuation(source[i + 2])) {
                const mapped = code + 0x60;
                out[i] = 0xe3;
                out[i + 1] = 0x80 | @as(u8, @intCast((mapped >> 6) & 0x3f));
                out[i + 2] = 0x80 | @as(u8, @intCast(mapped & 0x3f));
                i += 3;
                continue;
            }
        }
        out[i] = byte;
        i += 1;
    }
}

/// Decodes one entry record. Op-encoded features are appended to `out`;
/// raw records are returned as a slice of `record`. A corrupt record yields
/// an empty feature and leaves `out` unchanged.
///
/// With valid UTF-8 `surface`, every surface copy is a non-empty run of whole
/// characters and every column copy is a character-boundary prefix of a
/// column already emitted between `,` separators. The decoded feature is
/// therefore valid UTF-8 exactly when the record's own bytes (prefix entry
/// and literals) are, independent of the surface; callers memoize UTF-8
/// validation per word id on that basis.
pub fn decode(allocator: Allocator, table: Table, record: []const u8, surface: []const u8, out: *std.ArrayList(u8)) Allocator.Error!Decoded {
    var cursor: usize = 0;
    const head = readVarint(record, &cursor) orelse return .{ .borrowed = "" };
    if (head == 0) return .{ .borrowed = record[cursor..] };
    const prefix = table.prefix(head - 1) orelse return .{ .borrowed = "" };

    const start = out.items.len;
    // A decoded feature is at most the prefix plus, per op, one reference
    // copy (bounded by `max_decoded_len`) and its literal.
    try out.appendSlice(allocator, prefix);
    var column: usize = table.prefix_fields;
    var starts: [max_back_refs]usize = undefined;
    var lens: [max_back_refs]usize = undefined;
    var emitted: usize = 0;
    while (cursor < record.len) {
        const tag = record[cursor];
        cursor += 1;
        const reference = tag >> 5;
        const explicit = tag & explicit_len_bit != 0;
        var copy_len: usize = 0;
        if (explicit) {
            copy_len = readVarint(record, &cursor) orelse return corrupt(out, start);
            if (copy_len == 0 or reference == ref_none) return corrupt(out, start);
        }
        var literal_len: usize = tag & 0x0f;
        if (literal_len == inline_literal_limit) {
            literal_len += readVarint(record, &cursor) orelse return corrupt(out, start);
        }
        if (literal_len > record.len - cursor) return corrupt(out, start);

        // Resolve the reference against the surface or an earlier column.
        var source: []const u8 = &.{};
        var source_in_out = false;
        var source_start: usize = 0;
        switch (reference) {
            ref_none => {},
            ref_surface, ref_katakana => {
                if (surface.len == 0) return corrupt(out, start);
                source = surface;
            },
            else => {
                const back: usize = reference - ref_first_column + 1;
                if (back > @min(emitted, max_back_refs)) return corrupt(out, start);
                const slot = (emitted - back) % max_back_refs;
                source_start = starts[slot];
                source = out.items[source_start..][0..lens[slot]];
                source_in_out = true;
            },
        }
        if (!explicit) copy_len = source.len;
        if (copy_len > source.len or !isCopyBoundary(source, copy_len)) return corrupt(out, start);

        const separator: usize = @intFromBool(column != 0);
        const field_len = copy_len + literal_len;
        if (out.items.len - start + separator + field_len > max_decoded_len) return corrupt(out, start);
        try out.ensureUnusedCapacity(allocator, separator + field_len);
        if (separator != 0) out.appendAssumeCapacity(',');
        const field_start = out.items.len;
        const dest = out.addManyAsSliceAssumeCapacity(field_len);
        if (source_in_out) {
            // Re-slice after `ensureUnusedCapacity`, which may have moved `out`.
            @memcpy(dest[0..copy_len], out.items[source_start..][0..copy_len]);
        } else if (reference == ref_katakana) {
            appendKatakana(dest[0..copy_len], source[0..copy_len]);
        } else {
            @memcpy(dest[0..copy_len], source[0..copy_len]);
        }
        @memcpy(dest[copy_len..], record[cursor..][0..literal_len]);
        cursor += literal_len;

        const slot = emitted % max_back_refs;
        starts[slot] = field_start;
        lens[slot] = field_len;
        emitted += 1;
        column += 1;
    }
    return .{ .appended = out.items.len - start };
}

fn corrupt(out: *std.ArrayList(u8), start: usize) Decoded {
    out.shrinkRetainingCapacity(start);
    return .{ .borrowed = "" };
}

// ---------------------------------------------------------------------------
// Encoder (dictionary build time)

/// Build-time encoder: owns the prefix table and produces per-entry records.
pub const Encoder = struct {
    allocator: Allocator,
    prefix_fields: u32,
    /// Prefix strings in table order (slices of the source features).
    prefixes: [][]const u8,
    ids: std.StringHashMapUnmanaged(u32),
    scratch: std.ArrayList(u8) = .empty,
    kana: std.ArrayList(u8) = .empty,

    /// Chooses the prefix column count and builds the table. Among the
    /// leading-column counts whose distinct combinations stay small relative
    /// to the dictionary, it keeps the one with the largest estimated saving.
    /// The table is ordered by descending frequency (ties by first
    /// appearance) so frequent prefixes get one-byte ids. `entries` is any
    /// slice of values with `surface` and `feature` byte-slice fields.
    pub fn init(allocator: Allocator, entries: anytype) !Encoder {
        const limit = @max(256, entries.len / 32);
        var prefix_fields: u32 = 0;
        var best_saving: usize = 0;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);
        var fields: u32 = 1;
        while (fields <= max_prefix_fields) : (fields += 1) {
            seen.clearRetainingCapacity();
            var covered: usize = 0;
            var eligible: usize = 0;
            var table_bytes: usize = 0;
            for (entries) |entry| {
                const prefix = leadingColumns(entry.feature, fields) orelse continue;
                eligible += 1;
                covered += prefix.len;
                const gop = try seen.getOrPut(allocator, prefix);
                if (!gop.found_existing) {
                    table_bytes += prefix.len + 4;
                    if (seen.count() > limit) break;
                }
            }
            if (eligible == 0 or seen.count() > limit) break;
            // Each covered entry still spends about one byte on its id.
            const cost = table_bytes + eligible;
            if (covered > cost and covered - cost > best_saving) {
                best_saving = covered - cost;
                prefix_fields = fields;
            }
        }

        var self: Encoder = .{
            .allocator = allocator,
            .prefix_fields = prefix_fields,
            .prefixes = &.{},
            .ids = .empty,
        };
        errdefer self.deinit();
        if (prefix_fields == 0) return self;

        const Stat = struct { prefix: []const u8, count: u32, first: u32 };
        var stats: std.ArrayList(Stat) = .empty;
        defer stats.deinit(allocator);
        var index_of: std.StringHashMapUnmanaged(u32) = .empty;
        defer index_of.deinit(allocator);
        for (entries, 0..) |entry, entry_index| {
            const prefix = leadingColumns(entry.feature, prefix_fields) orelse continue;
            const gop = try index_of.getOrPut(allocator, prefix);
            if (gop.found_existing) {
                stats.items[gop.value_ptr.*].count += 1;
            } else {
                gop.value_ptr.* = @intCast(stats.items.len);
                try stats.append(allocator, .{ .prefix = prefix, .count = 1, .first = @intCast(entry_index) });
            }
        }
        std.mem.sort(Stat, stats.items, {}, struct {
            fn lessThan(_: void, lhs: Stat, rhs: Stat) bool {
                if (lhs.count != rhs.count) return lhs.count > rhs.count;
                return lhs.first < rhs.first;
            }
        }.lessThan);
        self.prefixes = try allocator.alloc([]const u8, stats.items.len);
        for (stats.items, self.prefixes, 0..) |stat, *prefix, id| {
            prefix.* = stat.prefix;
            try self.ids.put(allocator, stat.prefix, @intCast(id));
        }
        return self;
    }

    pub fn deinit(self: *Encoder) void {
        self.ids.deinit(self.allocator);
        self.allocator.free(self.prefixes);
        self.scratch.deinit(self.allocator);
        self.kana.deinit(self.allocator);
    }

    pub fn tableBlobLen(self: *const Encoder) usize {
        var total: usize = 0;
        for (self.prefixes) |prefix| total += prefix.len;
        return total;
    }

    /// Appends the record for one entry to `out`.
    pub fn encode(self: *Encoder, out: *std.ArrayList(u8), surface: []const u8, feature: []const u8) !void {
        const allocator = self.allocator;
        const raw_len = 1 + feature.len;
        encoded: {
            if (self.prefix_fields == 0 or feature.len > max_decoded_len) break :encoded;
            const prefix = leadingColumns(feature, self.prefix_fields) orelse break :encoded;
            const id = self.ids.get(prefix) orelse break :encoded;
            const scratch = &self.scratch;
            scratch.clearRetainingCapacity();
            try appendVarint(allocator, scratch, @as(usize, id) + 1);

            self.kana.clearRetainingCapacity();
            try self.kana.resize(allocator, surface.len);
            appendKatakana(self.kana.items, surface);
            const has_katakana = !std.mem.eql(u8, self.kana.items, surface);

            var previous: [max_back_refs][]const u8 = undefined;
            var emitted: usize = 0;
            var rest = feature[prefix.len..];
            // `rest` is empty (exactly `prefix_fields` columns) or starts with
            // the separator of the next column.
            while (rest.len != 0) {
                rest = rest[1..];
                const column_end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
                const column = rest[0..column_end];
                rest = rest[column_end..];

                var best_ref: u8 = ref_none;
                var best_copy: usize = 0;
                var best_source_len: usize = 0;
                var best_cost = opCost(false, 0, column.len);
                var candidate: u8 = ref_surface;
                while (candidate < ref_first_column + max_back_refs) : (candidate += 1) {
                    const source: []const u8 = switch (candidate) {
                        ref_surface => surface,
                        ref_katakana => if (has_katakana) self.kana.items else continue,
                        else => blk: {
                            const back: usize = candidate - ref_first_column + 1;
                            if (back > @min(emitted, max_back_refs)) continue;
                            break :blk previous[(emitted - back) % max_back_refs];
                        },
                    };
                    var copy = commonPrefixLen(column, source);
                    while (copy != 0 and !isCopyBoundary(source, copy)) copy -= 1;
                    if (copy == 0) continue;
                    const cost = opCost(copy != source.len, copy, column.len - copy);
                    if (cost < best_cost) {
                        best_cost = cost;
                        best_ref = candidate;
                        best_copy = copy;
                        best_source_len = source.len;
                    }
                }
                const explicit = best_ref != ref_none and best_copy != best_source_len;
                const literal = column[best_copy..];
                const inline_len: u8 = @intCast(@min(literal.len, inline_literal_limit));
                try scratch.append(allocator, (best_ref << 5) | (if (explicit) explicit_len_bit else 0) | inline_len);
                if (explicit) try appendVarint(allocator, scratch, best_copy);
                if (literal.len >= inline_literal_limit) try appendVarint(allocator, scratch, literal.len - inline_literal_limit);
                try scratch.appendSlice(allocator, literal);

                previous[emitted % max_back_refs] = column;
                emitted += 1;
            }
            if (scratch.items.len >= raw_len) break :encoded;
            try out.appendSlice(allocator, scratch.items);
            return;
        }
        try out.append(allocator, 0);
        try out.appendSlice(allocator, feature);
    }
};

fn opCost(explicit: bool, copy_len: usize, literal_len: usize) usize {
    var cost: usize = 1 + literal_len;
    if (explicit) cost += varintLen(copy_len);
    if (literal_len >= inline_literal_limit) cost += varintLen(literal_len - inline_literal_limit);
    return cost;
}

fn commonPrefixLen(lhs: []const u8, rhs: []const u8) usize {
    const len = @min(lhs.len, rhs.len);
    var i: usize = 0;
    while (i < len and lhs[i] == rhs[i]) i += 1;
    return i;
}

/// The first `fields` columns of `feature` (without the trailing separator),
/// or null when it has fewer columns.
fn leadingColumns(feature: []const u8, fields: u32) ?[]const u8 {
    var seen: u32 = 0;
    for (feature, 0..) |byte, i| {
        if (byte == ',') {
            seen += 1;
            if (seen == fields) return feature[0..i];
        }
    }
    return if (seen + 1 == fields) feature else null;
}

fn varintLen(value: usize) usize {
    var len: usize = 1;
    var rest = value >> 7;
    while (rest != 0) : (rest >>= 7) len += 1;
    return len;
}

fn appendVarint(allocator: Allocator, out: *std.ArrayList(u8), value: usize) !void {
    var rest = value;
    while (rest >= 0x80) : (rest >>= 7) try out.append(allocator, @as(u8, @truncate(rest)) | 0x80);
    try out.append(allocator, @truncate(rest));
}

const TestEntry = struct { surface: []const u8, feature: []const u8 };

fn buildTestTable(allocator: Allocator, encoder: *const Encoder, offsets: *std.ArrayList(u32), blob: *std.ArrayList(u8)) !Table {
    for (encoder.prefixes) |prefix| {
        try offsets.append(allocator, @intCast(blob.items.len));
        try blob.appendSlice(allocator, prefix);
    }
    try offsets.append(allocator, @intCast(blob.items.len));
    return .{ .prefix_fields = encoder.prefix_fields, .offsets = offsets.items, .blob = blob.items };
}

test "feature records round-trip through the encoder" {
    const allocator = std.testing.allocator;
    const samples = [_]TestEntry{
        .{ .surface = "やぼったい", .feature = "形容詞,自立,*,*,形容詞・アウオ段,基本形,やぼったい,ヤボッタイ,ヤボッタイ" },
        .{ .surface = "やぼったから", .feature = "形容詞,自立,*,*,形容詞・アウオ段,未然ヌ接続,やぼったい,ヤボッタカラ,ヤボッタカラ" },
        .{ .surface = "東京", .feature = "名詞,固有名詞,地域,一般,*,*,東京,トウキョウ,トーキョー" },
        .{ .surface = "x", .feature = "short" },
        .{ .surface = "y", .feature = "" },
        .{ .surface = "", .feature = "名詞,一般,*,*,*,*,,," },
        .{ .surface = "z", .feature = "a,b,c,d,e,f,,," },
        .{ .surface = "長い", .feature = "名詞,一般,*,*,*,*,長い,ナガイナガイナガイナガイナガイナガイ,ナガイナガイナガイナガイナガイナガイ" },
        .{ .surface = "ぁゖゔ", .feature = "名詞,一般,*,*,*,*,ぁゖゔ,ァヶヴ,ァヶヴ" },
    };
    // Vary the seventh column of repeated samples so, as in real
    // dictionaries, only the part-of-speech prefix is worth a table.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var entries: std.ArrayList(TestEntry) = .empty;
    defer entries.deinit(allocator);
    for (0..40) |index| {
        for (samples) |sample| {
            const head = leadingColumns(sample.feature, 6) orelse sample.feature;
            const feature = try std.fmt.allocPrint(arena, "{s},{d}{s}", .{ head, index, sample.feature[head.len..] });
            try entries.append(allocator, .{ .surface = sample.surface, .feature = feature });
        }
    }

    var encoder = try Encoder.init(allocator, entries.items);
    defer encoder.deinit();
    try std.testing.expectEqual(@as(u32, 6), encoder.prefix_fields);
    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(allocator);
    var table_blob: std.ArrayList(u8) = .empty;
    defer table_blob.deinit(allocator);
    const table = try buildTestTable(allocator, &encoder, &offsets, &table_blob);

    var record: std.ArrayList(u8) = .empty;
    defer record.deinit(allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var encoded_total: usize = 0;
    for (samples) |entry| {
        record.clearRetainingCapacity();
        try encoder.encode(&record, entry.surface, entry.feature);
        encoded_total += record.items.len;
        try std.testing.expect(record.items.len <= entry.feature.len + 1);
        try out.appendSlice(allocator, "junk");
        const decoded = try decode(allocator, table, record.items, entry.surface, &out);
        const feature = switch (decoded) {
            .borrowed => |bytes| bytes,
            .appended => |len| out.items[out.items.len - len ..],
        };
        try std.testing.expectEqualStrings(entry.feature, feature);
        out.clearRetainingCapacity();
    }
    var raw_total: usize = 0;
    for (samples) |entry| raw_total += entry.feature.len;
    try std.testing.expect(encoded_total * 3 < raw_total);
}

test "katakana mapping covers the hiragana block only" {
    var out: [18]u8 = undefined;
    appendKatakana(&out, "ぁゖ゗ゝaー");
    try std.testing.expectEqualStrings("ァヶ゗ゝaー", out[0.."ァヶ゗ゝaー".len]);
}

test "corrupt feature records decode to an empty feature" {
    const allocator = std.testing.allocator;
    const offsets = [_]u32{ 0, 3 };
    const table: Table = .{ .prefix_fields = 1, .offsets = &offsets, .blob = "abc" };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const records = [_][]const u8{
        "",
        "\x80",
        "\x02",
        "\x01\x05ab",
        "\x01\x30\x09",
        "\x01\x30\x00",
        "\x01\x60",
        "\x01\x0f",
        "\x01\x30\x02",
    };
    for (records) |record| {
        const decoded = try decode(allocator, table, record, "あ", &out);
        try std.testing.expectEqualStrings("", decoded.borrowed);
        try std.testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

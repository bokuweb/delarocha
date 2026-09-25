const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const binary_magic_v1 = "DLRDIC01";
const binary_magic = "DLRDIC02";

pub const Entry = struct {
    surface: []const u8,
    left_id: u16,
    right_id: u16,
    word_cost: i32,
    feature: []const u8,
};

pub const UnkEntry = struct {
    category_id: usize,
    left_id: u16,
    right_id: u16,
    word_cost: i32,
    feature: []const u8,
};

pub const CharCategory = struct {
    name: []const u8,
    invoke: bool,
    group: bool,
    length: usize,
};

pub const CharRange = struct {
    start: u32,
    end: u32,
    category_ids: []usize,
};

pub const TrieEdge = extern struct {
    byte: u8 align(1),
    child: u32 align(1),
};

// Each trie node stores offsets into global edge/term streams. The in-memory
// layout is byte-for-byte the 22-byte DLRDIC02 record, so memory-mapped
// dictionaries borrow the node table instead of decoding ~1M nodes on every
// load (previously the largest load cost). Tokenization cycles with these
// unaligned fields matched the former packed 16-byte node on aarch64; the
// packed form only saved ~6 MiB for dictionaries that are copied or built
// from raw files.
pub const TrieNode = extern struct {
    edge_start: u32 align(1),
    edge_len: u16 align(1),
    word_start: u32 align(1),
    word_len: u32 align(1),
    count_word_start: u32 align(1),
    count_word_len: u32 align(1),
};

// Trie term streams are stored in the binary file with the exact in-memory
// layout, so borrowed (mmap) dictionaries slice them directly instead of
// decoding. `extern` pins the field order: the previous auto-layout structs
// were dumped verbatim, and Zig laid them out as (word_id, word_cost, left_id,
// right_id) / (word_cost, left_id, right_id). The explicit order below keeps
// files written by those versions loadable while no longer depending on the
// compiler's unspecified auto layout.
pub const TrieTerm = extern struct {
    word_id: u32,
    word_cost: i32,
    left_id: u16,
    right_id: u16,
};

// Count-only tokenization never needs the dictionary word id or feature
// payload. Keeping this term at 8 bytes reduces the hot trie term stream for
// `tokenizeCount` and avoids loading data that cannot affect the best path.
pub const TrieCountTerm = extern struct {
    word_cost: i32,
    left_id: u16,
    right_id: u16,
};

comptime {
    if (@sizeOf(TrieNode) != 22 or @sizeOf(TrieEdge) != 5 or @sizeOf(TrieTerm) != 12 or @sizeOf(TrieCountTerm) != 8) {
        @compileError("native trie struct layout must match the binary format");
    }
    if (@offsetOf(TrieTerm, "word_cost") != 4 or @offsetOf(TrieTerm, "left_id") != 8 or @offsetOf(TrieTerm, "right_id") != 10 or
        @offsetOf(TrieCountTerm, "left_id") != 4 or @offsetOf(TrieCountTerm, "right_id") != 6)
    {
        @compileError("trie term field offsets must match the binary format");
    }
}

pub const UnkTerm = struct {
    unk_id: u32,
    left_id: u16,
    right_id: u16,
    word_cost: i32,
};

// Binary dictionaries keep all known-word features in one blob. Storing an
// offset and length avoids one slice pointer per entry while preserving cheap
// feature lookup during full token backtrace.
pub const FeatureRef = extern struct {
    offset: u32 align(1),
    len: u32 align(1),
};

pub const EntryIndex = struct {
    buckets: [256][]u32,

    fn empty() EntryIndex {
        var buckets: [256][]u32 = undefined;
        for (&buckets) |*bucket| bucket.* = &.{};
        return .{ .buckets = buckets };
    }

    fn deinit(self: EntryIndex, allocator: Allocator) void {
        for (self.buckets) |bucket| {
            if (bucket.len != 0) allocator.free(bucket);
        }
    }
};

pub const UnkIndex = struct {
    buckets: [][]UnkTerm,
    count_buckets: [][]UnkTerm,
    fallback_terms: []UnkTerm,

    fn deinit(self: UnkIndex, allocator: Allocator) void {
        for (self.buckets) |bucket| {
            if (bucket.len != 0) allocator.free(bucket);
        }
        for (self.count_buckets) |bucket| {
            if (bucket.len != 0) allocator.free(bucket);
        }
        allocator.free(self.buckets);
        allocator.free(self.count_buckets);
        allocator.free(self.fallback_terms);
    }
};

pub const CharInfo = struct {
    base_id: usize,
    category_ids: []const usize,
    category: *const CharCategory,
};

pub const CharProperty = struct {
    allocator: Allocator,
    categories: []CharCategory,
    ranges: []CharRange,
    invoke_bmp: []u8,
    range_bmp: []u16,
    default_ids: [1]usize = .{0},
    has_invoke: bool = false,

    pub fn default(allocator: Allocator) !CharProperty {
        const categories = try allocator.alloc(CharCategory, 1);
        categories[0] = .{
            .name = try allocator.dupe(u8, "DEFAULT"),
            .invoke = false,
            .group = false,
            .length = 0,
        };
        const invoke_bmp = try buildInvokeBmp(allocator, categories, &.{});
        errdefer allocator.free(invoke_bmp);
        const range_bmp = try buildRangeBmp(allocator, &.{});
        return .{ .allocator = allocator, .categories = categories, .ranges = &.{}, .invoke_bmp = invoke_bmp, .range_bmp = range_bmp, .has_invoke = false };
    }

    pub fn parse(allocator: Allocator, input: []const u8) !CharProperty {
        var categories: std.ArrayList(CharCategory) = .empty;
        errdefer {
            for (categories.items) |category| allocator.free(category.name);
            categories.deinit(allocator);
        }

        var ranges: std.ArrayList(CharRange) = .empty;
        errdefer {
            for (ranges.items) |range| allocator.free(range.category_ids);
            ranges.deinit(allocator);
        }

        var lines = std.mem.splitScalar(u8, input, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.startsWith(u8, line, "0x")) {
                var fields = std.mem.tokenizeAny(u8, line, " \t");
                const range_text = fields.next() orelse return error.InvalidDictionary;
                const bounds = try parseCodepointRange(range_text);
                var ids: std.ArrayList(usize) = .empty;
                errdefer ids.deinit(allocator);
                while (fields.next()) |field| {
                    if (field[0] == '#') break;
                    try ids.append(allocator, findCategoryId(categories.items, field) orelse return error.InvalidDictionary);
                }
                if (ids.items.len == 0) return error.InvalidDictionary;
                try ranges.append(allocator, .{
                    .start = bounds.start,
                    .end = bounds.end,
                    .category_ids = try ids.toOwnedSlice(allocator),
                });
            } else {
                var fields = std.mem.tokenizeAny(u8, line, " \t");
                try categories.append(allocator, .{
                    .name = try allocator.dupe(u8, fields.next() orelse return error.InvalidDictionary),
                    .invoke = try parseBool01(fields.next() orelse return error.InvalidDictionary),
                    .group = try parseBool01(fields.next() orelse return error.InvalidDictionary),
                    .length = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidDictionary, 10),
                });
            }
        }

        if (findCategoryId(categories.items, "DEFAULT") == null) return error.InvalidDictionary;
        var has_invoke = false;
        for (categories.items) |category| {
            if (category.invoke) {
                has_invoke = true;
                break;
            }
        }
        const owned_categories = try categories.toOwnedSlice(allocator);
        errdefer {
            for (owned_categories) |category| allocator.free(category.name);
            allocator.free(owned_categories);
        }
        const owned_ranges = try ranges.toOwnedSlice(allocator);
        errdefer {
            for (owned_ranges) |range| allocator.free(range.category_ids);
            allocator.free(owned_ranges);
        }
        const invoke_bmp = try buildInvokeBmp(allocator, owned_categories, owned_ranges);
        errdefer allocator.free(invoke_bmp);
        const range_bmp = try buildRangeBmp(allocator, owned_ranges);
        errdefer allocator.free(range_bmp);
        return .{
            .allocator = allocator,
            .categories = owned_categories,
            .ranges = owned_ranges,
            .invoke_bmp = invoke_bmp,
            .range_bmp = range_bmp,
            .has_invoke = has_invoke,
        };
    }

    pub fn deinit(self: *CharProperty) void {
        for (self.categories) |category| self.allocator.free(category.name);
        for (self.ranges) |range| self.allocator.free(range.category_ids);
        self.allocator.free(self.categories);
        self.allocator.free(self.ranges);
        self.allocator.free(self.invoke_bmp);
        self.allocator.free(self.range_bmp);
    }

    pub fn categoryId(self: *const CharProperty, name: []const u8) ?usize {
        return findCategoryId(self.categories, name);
    }

    pub fn info(self: *const CharProperty, ch: u21) CharInfo {
        const cp: u32 = ch;
        if (cp < 0x10000) {
            const range_index = self.range_bmp[cp];
            if (range_index != invalid_range_index) {
                const range = self.ranges[@intCast(range_index)];
                const base = range.category_ids[0];
                return .{ .base_id = base, .category_ids = range.category_ids, .category = &self.categories[base] };
            }
            return .{ .base_id = 0, .category_ids = &self.default_ids, .category = &self.categories[0] };
        }
        var i = self.ranges.len;
        while (i > 0) {
            i -= 1;
            const range = self.ranges[i];
            if (range.start <= cp and cp < range.end) {
                const base = range.category_ids[0];
                return .{ .base_id = base, .category_ids = range.category_ids, .category = &self.categories[base] };
            }
        }
        return .{ .base_id = 0, .category_ids = &self.default_ids, .category = &self.categories[0] };
    }

    pub fn mayInvoke(self: *const CharProperty, ch: u21) bool {
        const cp: u32 = ch;
        if (cp < 0x10000) {
            const mask = @as(u8, 1) << @intCast(cp & 7);
            return self.invoke_bmp[cp >> 3] & mask != 0;
        }
        return self.info(ch).category.invoke;
    }
};

fn buildInvokeBmp(allocator: Allocator, categories: []const CharCategory, ranges: []const CharRange) ![]u8 {
    const invoke_bmp = try allocator.alloc(u8, 0x10000 / 8);
    @memset(invoke_bmp, if (categories[0].invoke) 0xff else 0);
    for (ranges) |range| {
        if (range.start >= 0x10000) continue;
        const end = @min(range.end, 0x10000);
        const invoke = categories[range.category_ids[0]].invoke;
        for (range.start..end) |cp| {
            const mask = @as(u8, 1) << @intCast(cp & 7);
            if (invoke) {
                invoke_bmp[cp >> 3] |= mask;
            } else {
                invoke_bmp[cp >> 3] &= ~mask;
            }
        }
    }
    return invoke_bmp;
}

const invalid_range_index = std.math.maxInt(u16);

fn buildRangeBmp(allocator: Allocator, ranges: []const CharRange) ![]u16 {
    if (ranges.len >= invalid_range_index) return error.InvalidDictionary;
    const range_bmp = try allocator.alloc(u16, 0x10000);
    @memset(range_bmp, invalid_range_index);
    for (ranges, 0..) |range, range_index| {
        if (range.start >= 0x10000) continue;
        const end = @min(range.end, 0x10000);
        @memset(range_bmp[@intCast(range.start)..@intCast(end)], @as(u16, @intCast(range_index)));
    }
    return range_bmp;
}

pub const ConnectionMatrix = struct {
    left_size: usize,
    right_size: usize,
    costs: []align(1) const i16,

    pub fn parseMinimal(allocator: Allocator, right_size: usize, left_size: usize, rows: []const []const u8) !ConnectionMatrix {
        var costs: std.ArrayList(i16) = .empty;
        errdefer costs.deinit(allocator);
        try costs.ensureTotalCapacity(allocator, right_size * left_size);
        for (rows) |line| {
            var cols = std.mem.splitScalar(u8, line, '\t');
            var count: usize = 0;
            while (cols.next()) |col| {
                try costs.append(allocator, try std.fmt.parseInt(i16, col, 10));
                count += 1;
            }
            if (count != left_size) return error.InvalidDictionary;
        }
        if (costs.items.len != right_size * left_size) return error.InvalidDictionary;
        return .{ .left_size = left_size, .right_size = right_size, .costs = try costs.toOwnedSlice(allocator) };
    }

    pub fn parseMecab(allocator: Allocator, input: []const u8) !ConnectionMatrix {
        var lines = std.mem.splitScalar(u8, input, '\n');
        const header = while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len != 0) break line;
        } else return error.InvalidDictionary;

        var header_fields = std.mem.tokenizeAny(u8, header, " \t");
        const right_size = try std.fmt.parseInt(usize, header_fields.next() orelse return error.InvalidDictionary, 10);
        const left_size = try std.fmt.parseInt(usize, header_fields.next() orelse return error.InvalidDictionary, 10);
        var costs = try allocator.alloc(i16, right_size * left_size);
        @memset(costs, 0);
        errdefer allocator.free(costs);

        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const right_id = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidDictionary, 10);
            const left_id = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidDictionary, 10);
            const parsed_cost = try std.fmt.parseInt(i16, fields.next() orelse return error.InvalidDictionary, 10);
            if (right_id >= right_size or left_id >= left_size) return error.InvalidDictionary;
            costs[left_id * right_size + right_id] = parsed_cost;
        }

        return .{ .left_size = left_size, .right_size = right_size, .costs = costs };
    }

    pub inline fn cost(self: ConnectionMatrix, right_id: u16, left_id: u16) i32 {
        const right = @as(usize, right_id);
        const left = @as(usize, left_id);
        if (right >= self.right_size or left >= self.left_size) return std.math.maxInt(i32) / 4;
        return @as(i32, self.costs[left * self.right_size + right]);
    }

    pub inline fn trustedCost(self: ConnectionMatrix, right_id: u16, left_id: u16) i32 {
        return @as(i32, self.costs[@as(usize, left_id) * self.right_size + @as(usize, right_id)]);
    }
};

pub const Dictionary = struct {
    allocator: Allocator,
    entries: []Entry,
    entry_features: []FeatureRef,
    // Binary dictionaries store entry surfaces and features in one contiguous
    // blob. Raw dictionaries leave this empty and keep per-entry ownership.
    entry_blob: []const u8,
    owns_entry_blob: bool,
    user_entries: []Entry,
    unk_entries: []UnkEntry,
    // Mirrors `entry_blob` for unknown-word features loaded from binary files.
    unk_feature_blob: []const u8,
    owns_unk_feature_blob: bool,
    unk_index: UnkIndex,
    char_property: CharProperty,
    matrix: ConnectionMatrix,
    owns_matrix_costs: bool,
    entry_index: EntryIndex,
    trie_nodes: []const TrieNode,
    // Edge and term streams are either allocator-owned or borrowed straight
    // from binary dictionary bytes (see `owns_trie_streams`). Borrowed streams
    // may start at any file offset, hence the align(1) element pointers; both
    // x86_64 and aarch64 load these without penalty.
    trie_edges: []const TrieEdge,
    trie_terms: []align(1) const TrieTerm,
    trie_count_terms: []align(1) const TrieCountTerm,
    owns_trie_streams: bool = true,
    trie_first: [256]u32,
    trie_bmp: []align(1) const u32,
    trie_pair: []align(1) const u32,
    trie_triple: []align(1) const u32,
    trie_base: []align(1) const u32,
    trie_check: []align(1) const u32,
    trie_child: []align(1) const u32,
    owns_trie_u32_tables: bool,
    // Read-only file mapping owned by this dictionary when it was loaded with
    // `fromBinaryFile`. Borrowed slices above point into it, so it is unmapped
    // last in `deinit`.
    mapped_file: ?MappedFile = null,

    pub fn parseMinimal(allocator: Allocator, input: []const u8) !Dictionary {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer freeEntries(allocator, entries.items);
        errdefer entries.deinit(allocator);

        var rows: std.ArrayList([]const u8) = .empty;
        defer rows.deinit(allocator);
        var left_size: usize = 0;
        var right_size: usize = 0;
        var pending_rows: usize = 0;
        var has_matrix = false;

        var lines = std.mem.splitScalar(u8, input, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (pending_rows > 0) {
                try rows.append(allocator, line);
                pending_rows -= 1;
                continue;
            }

            var fields = std.mem.splitScalar(u8, line, '\t');
            const kind = fields.next() orelse return error.InvalidDictionary;
            if (std.mem.eql(u8, kind, "matrix")) {
                right_size = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidDictionary, 10);
                left_size = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidDictionary, 10);
                pending_rows = right_size;
                has_matrix = true;
            } else if (std.mem.eql(u8, kind, "entry")) {
                try entries.append(allocator, try parseEntryFields(allocator, &fields));
            } else return error.InvalidDictionary;
        }

        if (!has_matrix or pending_rows != 0 or entries.items.len == 0) return error.InvalidDictionary;
        const owned_entries = try entries.toOwnedSlice(allocator);
        errdefer freeEntrySlice(allocator, owned_entries);
        const unk_entries = try defaultUnkEntries(allocator);
        errdefer freeUnkSlice(allocator, unk_entries);
        const char_property = try CharProperty.default(allocator);
        errdefer {
            var mutable = char_property;
            mutable.deinit();
        }
        const matrix = try ConnectionMatrix.parseMinimal(allocator, right_size, left_size, rows.items);
        errdefer freeI16Slice(allocator, matrix.costs);
        // Large dictionaries use the trie path exclusively; building the
        // first-byte entry index there only consumes memory and load time.
        const entry_index = if (owned_entries.len <= 32) try buildEntryIndex(allocator, owned_entries) else EntryIndex.empty();
        errdefer entry_index.deinit(allocator);
        const unk_index = try buildUnkIndex(allocator, char_property.categories.len, unk_entries, &matrix);
        errdefer unk_index.deinit(allocator);
        const trie = try buildTrie(allocator, owned_entries, &matrix);
        errdefer freeTrie(allocator, trie.nodes, trie.edges, trie.terms, trie.count_terms);
        const trie_pair = if (owned_entries.len <= 32) emptyU32Slice() else try buildTriePair(allocator, trie.nodes, trie.edges);
        errdefer if (trie_pair.len != 0) freeU32Slice(allocator, trie_pair);
        const trie_bmp = if (owned_entries.len <= 32) emptyU32Slice() else try buildTrieBmp(allocator, trie.nodes, trie.edges);
        errdefer if (trie_bmp.len != 0) freeU32Slice(allocator, trie_bmp);
        const trie_triple = try buildTrieTriple(allocator, trie.nodes, trie.edges);
        errdefer if (trie_triple.len != 0) freeU32Slice(allocator, trie_triple);
        const double_array = try buildDoubleArray(allocator, trie.nodes, trie.edges);
        errdefer freeDoubleArray(allocator, double_array);
        return .{
            .allocator = allocator,
            .entries = owned_entries,
            .entry_features = emptyFeatureRefSlice(),
            .entry_blob = emptyU8Slice(),
            .owns_entry_blob = false,
            .user_entries = &.{},
            .unk_entries = unk_entries,
            .unk_feature_blob = emptyU8Slice(),
            .owns_unk_feature_blob = false,
            .unk_index = unk_index,
            .char_property = char_property,
            .matrix = matrix,
            .owns_matrix_costs = true,
            .entry_index = entry_index,
            .trie_nodes = trie.nodes,
            .trie_edges = trie.edges,
            .trie_terms = trie.terms,
            .trie_count_terms = trie.count_terms,
            .trie_first = buildTrieFirst(trie.nodes, trie.edges),
            .trie_bmp = trie_bmp,
            .trie_pair = trie_pair,
            .trie_triple = trie_triple,
            .trie_base = double_array.base,
            .trie_check = double_array.check,
            .trie_child = double_array.child,
            .owns_trie_u32_tables = true,
        };
    }

    pub fn fromMinimalFile(allocator: Allocator, path: []const u8) !Dictionary {
        const bytes = try readFileAlloc(allocator, path);
        defer allocator.free(bytes);
        return parseMinimal(allocator, bytes);
    }

    /// Loads a binary dictionary file. Where the platform supports it the file
    /// is memory-mapped read-only and the dictionary borrows feature blobs,
    /// the connection matrix, and trie tables directly from the mapping, which
    /// the dictionary owns and unmaps in `deinit`. For IPADIC this loads
    /// several times faster than the copy path and keeps the dictionary in
    /// clean, file-backed pages instead of anonymous memory. As with
    /// any mmap, the file must not be truncated or rewritten in place while
    /// the dictionary is alive; use `fromBinaryFileCopy` when that cannot be
    /// guaranteed.
    pub fn fromBinaryFile(allocator: Allocator, path: []const u8) !Dictionary {
        if (comptime !MappedFile.supported) return fromBinaryFileCopy(allocator, path);
        var mapped = MappedFile.open(allocator, path) catch |err| switch (err) {
            // Some filesystems cannot be mapped; the copy loader still works.
            error.MemoryMappingNotSupported => return fromBinaryFileCopy(allocator, path),
            else => |e| return e,
        };
        errdefer mapped.close();
        var dict = try fromBorrowedBinaryBytes(allocator, mapped.bytes);
        dict.mapped_file = mapped;
        return dict;
    }

    /// Reads the whole file into memory and copies everything the dictionary
    /// needs into allocator-owned storage; the file may change afterwards.
    pub fn fromBinaryFileCopy(allocator: Allocator, path: []const u8) !Dictionary {
        const bytes = try readFileAlloc(allocator, path);
        defer allocator.free(bytes);
        return fromBinaryBytes(allocator, bytes);
    }

    pub fn fromRawFiles(allocator: Allocator, lex_path: []const u8, matrix_path: []const u8, char_path: []const u8, unk_path: []const u8) !Dictionary {
        const lex = try readFileAlloc(allocator, lex_path);
        defer allocator.free(lex);
        const matrix = try readFileAlloc(allocator, matrix_path);
        defer allocator.free(matrix);
        const char_def = try readFileAlloc(allocator, char_path);
        defer allocator.free(char_def);
        const unk = try readFileAlloc(allocator, unk_path);
        defer allocator.free(unk);
        return fromRawBytes(allocator, lex, matrix, char_def, unk);
    }

    pub fn fromRawBytes(allocator: Allocator, lex: []const u8, matrix_def: []const u8, char_def: []const u8, unk_def: []const u8) !Dictionary {
        var char_property = try CharProperty.parse(allocator, char_def);
        errdefer char_property.deinit();
        const entries = try parseEntries(allocator, lex);
        errdefer freeEntrySlice(allocator, entries);
        const unk_entries = try parseUnkEntries(allocator, unk_def, &char_property);
        errdefer freeUnkSlice(allocator, unk_entries);
        const matrix = try ConnectionMatrix.parseMecab(allocator, matrix_def);
        errdefer freeI16Slice(allocator, matrix.costs);
        // Large dictionaries use the trie path exclusively; building the
        // first-byte entry index there only consumes memory and load time.
        const entry_index = if (entries.len <= 32) try buildEntryIndex(allocator, entries) else EntryIndex.empty();
        errdefer entry_index.deinit(allocator);
        const unk_index = try buildUnkIndex(allocator, char_property.categories.len, unk_entries, &matrix);
        errdefer unk_index.deinit(allocator);
        const trie = try buildTrie(allocator, entries, &matrix);
        errdefer freeTrie(allocator, trie.nodes, trie.edges, trie.terms, trie.count_terms);
        const trie_pair = if (entries.len <= 32) emptyU32Slice() else try buildTriePair(allocator, trie.nodes, trie.edges);
        errdefer if (trie_pair.len != 0) freeU32Slice(allocator, trie_pair);
        const trie_bmp = if (entries.len <= 32) emptyU32Slice() else try buildTrieBmp(allocator, trie.nodes, trie.edges);
        errdefer if (trie_bmp.len != 0) freeU32Slice(allocator, trie_bmp);
        const trie_triple = try buildTrieTriple(allocator, trie.nodes, trie.edges);
        errdefer if (trie_triple.len != 0) freeU32Slice(allocator, trie_triple);
        const double_array = try buildDoubleArray(allocator, trie.nodes, trie.edges);
        errdefer freeDoubleArray(allocator, double_array);
        return .{
            .allocator = allocator,
            .entries = entries,
            .entry_features = emptyFeatureRefSlice(),
            .entry_blob = emptyU8Slice(),
            .owns_entry_blob = false,
            .user_entries = &.{},
            .unk_entries = unk_entries,
            .unk_feature_blob = emptyU8Slice(),
            .owns_unk_feature_blob = false,
            .unk_index = unk_index,
            .char_property = char_property,
            .matrix = matrix,
            .owns_matrix_costs = true,
            .entry_index = entry_index,
            .trie_nodes = trie.nodes,
            .trie_edges = trie.edges,
            .trie_terms = trie.terms,
            .trie_count_terms = trie.count_terms,
            .trie_first = buildTrieFirst(trie.nodes, trie.edges),
            .trie_bmp = trie_bmp,
            .trie_pair = trie_pair,
            .trie_triple = trie_triple,
            .trie_base = double_array.base,
            .trie_check = double_array.check,
            .trie_child = double_array.child,
            .owns_trie_u32_tables = true,
        };
    }

    pub fn toBinaryAlloc(self: *const Dictionary, allocator: Allocator) ![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);
        try bytes.ensureTotalCapacity(allocator, try self.binarySize());
        try bytes.appendSlice(allocator, binary_magic);

        try appendU32(allocator, &bytes, @intCast(self.entries.len));
        try appendU32(allocator, &bytes, @intCast(self.unk_entries.len));
        try appendU32(allocator, &bytes, @intCast(self.char_property.categories.len));
        try appendU32(allocator, &bytes, @intCast(self.char_property.ranges.len));
        try appendU32(allocator, &bytes, @intCast(self.matrix.right_size));
        try appendU32(allocator, &bytes, @intCast(self.matrix.left_size));

        for (self.entries) |entry| {
            try appendU32(allocator, &bytes, @intCast(entry.surface.len));
            try appendU16(allocator, &bytes, entry.left_id);
            try appendU16(allocator, &bytes, entry.right_id);
            try appendI32(allocator, &bytes, entry.word_cost);
            try appendU32(allocator, &bytes, @intCast(entry.feature.len));
            try bytes.appendSlice(allocator, entry.surface);
            try bytes.appendSlice(allocator, entry.feature);
        }

        for (self.unk_entries) |entry| {
            try appendU32(allocator, &bytes, @intCast(entry.category_id));
            try appendU16(allocator, &bytes, entry.left_id);
            try appendU16(allocator, &bytes, entry.right_id);
            try appendI32(allocator, &bytes, entry.word_cost);
            try appendU32(allocator, &bytes, @intCast(entry.feature.len));
            try bytes.appendSlice(allocator, entry.feature);
        }

        for (self.char_property.categories) |category| {
            try appendU32(allocator, &bytes, @intCast(category.name.len));
            try bytes.append(allocator, if (category.invoke) 1 else 0);
            try bytes.append(allocator, if (category.group) 1 else 0);
            try appendU32(allocator, &bytes, @intCast(category.length));
            try bytes.appendSlice(allocator, category.name);
        }

        for (self.char_property.ranges) |range| {
            try appendU32(allocator, &bytes, range.start);
            try appendU32(allocator, &bytes, range.end);
            try appendU32(allocator, &bytes, @intCast(range.category_ids.len));
            for (range.category_ids) |category_id| try appendU32(allocator, &bytes, @intCast(category_id));
        }

        try appendI16Slice(allocator, &bytes, self.matrix.costs);

        // Binary v2 stores the expensive derived lookup structures directly.
        // Loading the previous format rebuilt the trie and double-array from
        // all entries, causing multi-second startup and very high peak RSS for
        // large dictionaries such as IPADIC.
        try appendU32(allocator, &bytes, @intCast(self.trie_nodes.len));
        try appendU32(allocator, &bytes, @intCast(self.trie_edges.len));
        try appendU32(allocator, &bytes, @intCast(self.trie_terms.len));
        try appendU32(allocator, &bytes, @intCast(self.trie_count_terms.len));
        try appendU32(allocator, &bytes, @intCast(self.trie_pair.len));
        try appendU32(allocator, &bytes, @intCast(self.trie_bmp.len));
        try appendU32(allocator, &bytes, @intCast(self.trie_triple.len));
        try appendU32(allocator, &bytes, @intCast(self.trie_base.len));
        try appendU32(allocator, &bytes, @intCast(self.trie_check.len));
        try appendU32(allocator, &bytes, @intCast(self.trie_child.len));

        try appendNativeStructSlice(TrieNode, allocator, &bytes, self.trie_nodes);
        try appendNativeStructSlice(TrieEdge, allocator, &bytes, self.trie_edges);
        try appendNativeStructSlice(TrieTerm, allocator, &bytes, self.trie_terms);
        try appendNativeStructSlice(TrieCountTerm, allocator, &bytes, self.trie_count_terms);
        try appendU32Slice(allocator, &bytes, self.trie_pair);
        try appendU32Slice(allocator, &bytes, self.trie_bmp);
        try appendU32Slice(allocator, &bytes, self.trie_triple);
        try appendU32Slice(allocator, &bytes, self.trie_base);
        try appendU32Slice(allocator, &bytes, self.trie_check);
        try appendU32Slice(allocator, &bytes, self.trie_child);
        return bytes.toOwnedSlice(allocator);
    }

    fn binarySize(self: *const Dictionary) !usize {
        var size: usize = binary_magic.len + 6 * 4 + 10 * 4;
        for (self.entries) |entry| size = try addSizes(size, .{ 16, entry.surface.len, entry.feature.len });
        for (self.unk_entries) |entry| size = try addSizes(size, .{ 16, entry.feature.len });
        for (self.char_property.categories) |category| size = try addSizes(size, .{ 10, category.name.len });
        for (self.char_property.ranges) |range| {
            size = try addSizes(size, .{ 12, try std.math.mul(usize, range.category_ids.len, 4) });
        }
        size = try addSizes(size, .{try std.math.mul(usize, self.matrix.costs.len, 2)});
        size = try addSizes(size, .{try std.math.mul(usize, self.trie_nodes.len, 22)});
        size = try addSizes(size, .{try std.math.mul(usize, self.trie_edges.len, 5)});
        size = try addSizes(size, .{try std.math.mul(usize, self.trie_terms.len, 12)});
        size = try addSizes(size, .{try std.math.mul(usize, self.trie_count_terms.len, 8)});
        for ([_][]align(1) const u32{ self.trie_pair, self.trie_bmp, self.trie_triple, self.trie_base, self.trie_check, self.trie_child }) |table| {
            size = try addSizes(size, .{try std.math.mul(usize, table.len, 4)});
        }
        return size;
    }

    /// Copies everything out of `bytes`; the caller may free them afterwards.
    pub fn fromBinaryBytes(allocator: Allocator, bytes: []const u8) !Dictionary {
        return fromBinaryBytesInternal(allocator, bytes, true);
    }

    /// Borrows feature blobs and (on little-endian targets) the matrix, trie
    /// edge/term streams, and lookup tables from `bytes`, which must stay
    /// alive and unchanged until `deinit`.
    pub fn fromBorrowedBinaryBytes(allocator: Allocator, bytes: []const u8) !Dictionary {
        return fromBinaryBytesInternal(allocator, bytes, false);
    }

    fn fromBinaryBytesInternal(allocator: Allocator, bytes: []const u8, copy_feature_blob: bool) !Dictionary {
        var cursor: usize = 0;
        const magic = try readSlice(bytes, &cursor, binary_magic.len);
        const has_prebuilt_trie = if (std.mem.eql(u8, magic, binary_magic))
            true
        else if (std.mem.eql(u8, magic, binary_magic_v1))
            false
        else
            return error.InvalidDictionary;

        const entry_count = try readU32(bytes, &cursor);
        const unk_count = try readU32(bytes, &cursor);
        const category_count = try readU32(bytes, &cursor);
        const range_count = try readU32(bytes, &cursor);
        const right_size = try readU32(bytes, &cursor);
        const left_size = try readU32(bytes, &cursor);
        const borrow_binary_tables = !copy_feature_blob and builtin.cpu.arch.endian() == .little;

        const compact_entry_features = has_prebuilt_trie and entry_count > 32;
        const entries = if (compact_entry_features)
            emptyEntrySlice()
        else
            try allocator.alloc(Entry, @intCast(entry_count));
        errdefer if (!compact_entry_features) allocator.free(entries);
        const entry_features = if (compact_entry_features)
            try allocator.alloc(FeatureRef, @intCast(entry_count))
        else
            emptyFeatureRefSlice();
        errdefer if (compact_entry_features) allocator.free(entry_features);
        const entry_blob_owned = if (copy_feature_blob)
            try allocator.alloc(u8, if (compact_entry_features)
                try scanBinaryEntryFeatureBlobLen(bytes, cursor, @intCast(entry_count))
            else
                try scanBinaryEntryBlobLen(bytes, cursor, @intCast(entry_count)))
        else
            emptyU8Slice();
        const entry_blob: []const u8 = if (copy_feature_blob) entry_blob_owned else bytes;
        errdefer if (copy_feature_blob) allocator.free(entry_blob_owned);
        var entry_blob_cursor: usize = 0;
        if (compact_entry_features) {
            // Hot path for large dictionaries: only the feature location is
            // needed, so skip the per-field decode and read the two lengths
            // from the fixed 16-byte record header.
            for (entry_features) |*ref| {
                const surface_len, const feature_len = try readBinaryEntryLens(bytes, &cursor);
                cursor += surface_len;
                const feature_offset = if (copy_feature_blob) copied: {
                    const feature_start = entry_blob_cursor;
                    @memcpy(entry_blob_owned[feature_start .. feature_start + feature_len], bytes[cursor .. cursor + feature_len]);
                    entry_blob_cursor += feature_len;
                    break :copied feature_start;
                } else cursor;
                cursor += feature_len;
                if (feature_offset > std.math.maxInt(u32)) return error.InvalidDictionary;
                ref.* = .{ .offset = @intCast(feature_offset), .len = @intCast(feature_len) };
            }
        } else for (0..@intCast(entry_count)) |entry_index| {
            const surface_len: usize = @intCast(try readU32(bytes, &cursor));
            const left_id = try readU16(bytes, &cursor);
            const right_id = try readU16(bytes, &cursor);
            const word_cost = try readI32(bytes, &cursor);
            const feature_len: usize = @intCast(try readU32(bytes, &cursor));
            const surface = try readSlice(bytes, &cursor, surface_len);
            const feature = try readSlice(bytes, &cursor, feature_len);
            const entry_surface, const entry_feature = if (copy_feature_blob) copied: {
                const surface_start = entry_blob_cursor;
                @memcpy(entry_blob_owned[surface_start .. surface_start + surface_len], surface);
                entry_blob_cursor += surface_len;
                const feature_start = entry_blob_cursor;
                @memcpy(entry_blob_owned[feature_start .. feature_start + feature_len], feature);
                entry_blob_cursor += feature_len;
                break :copied .{
                    entry_blob_owned[surface_start .. surface_start + surface_len],
                    entry_blob_owned[feature_start .. feature_start + feature_len],
                };
            } else .{ surface, feature };
            entries[entry_index] = .{
                .surface = entry_surface,
                .left_id = left_id,
                .right_id = right_id,
                .word_cost = word_cost,
                .feature = entry_feature,
            };
        }

        const unk_entries = try allocator.alloc(UnkEntry, @intCast(unk_count));
        errdefer allocator.free(unk_entries);
        const unk_feature_blob_owned = if (copy_feature_blob)
            try allocator.alloc(u8, try scanBinaryUnkFeatureBlobLen(bytes, cursor, @intCast(unk_count)))
        else
            emptyU8Slice();
        const unk_feature_blob: []const u8 = if (copy_feature_blob) unk_feature_blob_owned else bytes;
        errdefer if (copy_feature_blob) allocator.free(unk_feature_blob_owned);
        var unk_feature_blob_cursor: usize = 0;
        for (unk_entries) |*entry| {
            const category_id = try readU32(bytes, &cursor);
            const left_id = try readU16(bytes, &cursor);
            const right_id = try readU16(bytes, &cursor);
            const word_cost = try readI32(bytes, &cursor);
            const feature_len: usize = @intCast(try readU32(bytes, &cursor));
            const feature = try readSlice(bytes, &cursor, feature_len);
            const entry_feature = if (copy_feature_blob) copied: {
                const feature_start = unk_feature_blob_cursor;
                @memcpy(unk_feature_blob_owned[feature_start .. feature_start + feature_len], feature);
                unk_feature_blob_cursor += feature_len;
                break :copied unk_feature_blob_owned[feature_start .. feature_start + feature_len];
            } else feature;
            entry.* = .{
                .category_id = category_id,
                .left_id = left_id,
                .right_id = right_id,
                .word_cost = word_cost,
                .feature = entry_feature,
            };
        }

        const categories = try allocator.alloc(CharCategory, @intCast(category_count));
        // Initialize first so the errdefer never frees undefined names when a
        // truncated file fails part-way through the loop.
        @memset(categories, .{ .name = &.{}, .invoke = false, .group = false, .length = 0 });
        errdefer {
            for (categories) |category| allocator.free(category.name);
            allocator.free(categories);
        }
        var has_invoke = false;
        for (categories) |*category| {
            const name_len: usize = @intCast(try readU32(bytes, &cursor));
            const invoke = (try readU8(bytes, &cursor)) != 0;
            const group = (try readU8(bytes, &cursor)) != 0;
            const length: usize = @intCast(try readU32(bytes, &cursor));
            category.* = .{
                .name = try allocator.dupe(u8, try readSlice(bytes, &cursor, name_len)),
                .invoke = invoke,
                .group = group,
                .length = length,
            };
            has_invoke = has_invoke or invoke;
        }

        const ranges = try allocator.alloc(CharRange, @intCast(range_count));
        @memset(ranges, .{ .start = 0, .end = 0, .category_ids = &.{} });
        errdefer {
            for (ranges) |range| allocator.free(range.category_ids);
            allocator.free(ranges);
        }
        for (ranges) |*range| {
            const start = try readU32(bytes, &cursor);
            const end = try readU32(bytes, &cursor);
            const id_count: usize = @intCast(try readU32(bytes, &cursor));
            const raw_ids = try readSlice(bytes, &cursor, try std.math.mul(usize, id_count, 4));
            const ids = try allocator.alloc(usize, id_count);
            var raw_cursor: usize = 0;
            for (ids) |*id| id.* = readU32(raw_ids, &raw_cursor) catch unreachable;
            range.* = .{ .start = start, .end = end, .category_ids = ids };
        }

        const matrix_len = @as(usize, @intCast(right_size)) * @as(usize, @intCast(left_size));
        const costs = try readI16Slice(allocator, bytes, &cursor, matrix_len, borrow_binary_tables);
        errdefer if (!borrow_binary_tables) freeI16Slice(allocator, costs);
        const matrix: ConnectionMatrix = .{ .left_size = @intCast(left_size), .right_size = @intCast(right_size), .costs = costs };

        const invoke_bmp = try buildInvokeBmp(allocator, categories, ranges);
        errdefer allocator.free(invoke_bmp);
        const range_bmp = try buildRangeBmp(allocator, ranges);
        errdefer allocator.free(range_bmp);
        const char_property: CharProperty = .{
            .allocator = allocator,
            .categories = categories,
            .ranges = ranges,
            .invoke_bmp = invoke_bmp,
            .range_bmp = range_bmp,
            .has_invoke = has_invoke,
        };
        // No `errdefer char_property.deinit()`: the per-component errdefers
        // above already release these buffers on failure.
        const entry_index = if (entries.len <= 32) try buildEntryIndex(allocator, entries) else EntryIndex.empty();
        errdefer entry_index.deinit(allocator);
        const unk_index = try buildUnkIndex(allocator, @intCast(category_count), unk_entries, &matrix);
        errdefer unk_index.deinit(allocator);

        var trie_nodes: []const TrieNode = &.{};
        var trie_edges: []const TrieEdge = &.{};
        var trie_terms: []align(1) const TrieTerm = &.{};
        var trie_count_terms: []align(1) const TrieCountTerm = &.{};
        var owns_trie_streams = true;
        var trie_pair: []align(1) const u32 = &.{};
        var trie_bmp: []align(1) const u32 = &.{};
        var trie_triple: []align(1) const u32 = &.{};
        var trie_base: []align(1) const u32 = &.{};
        var trie_check: []align(1) const u32 = &.{};
        var trie_child: []align(1) const u32 = &.{};
        var owns_trie_u32_tables = true;
        // One function-scope cleanup: errdefers inside the branches below
        // would not cover the trailing length check.
        errdefer {
            if (owns_trie_streams) {
                if (trie_nodes.len != 0) freeAlign1Slice(TrieNode, allocator, trie_nodes);
                if (trie_edges.len != 0) freeAlign1Slice(TrieEdge, allocator, trie_edges);
                if (trie_terms.len != 0) freeAlign1Slice(TrieTerm, allocator, trie_terms);
                if (trie_count_terms.len != 0) freeAlign1Slice(TrieCountTerm, allocator, trie_count_terms);
            }
            if (owns_trie_u32_tables) {
                for ([_][]align(1) const u32{ trie_pair, trie_bmp, trie_triple, trie_base, trie_check, trie_child }) |table| {
                    if (table.len != 0) freeU32Slice(allocator, table);
                }
            }
        }

        if (has_prebuilt_trie) {
            const trie_node_count = try readU32(bytes, &cursor);
            const trie_edge_count = try readU32(bytes, &cursor);
            const trie_term_count = try readU32(bytes, &cursor);
            const trie_count_term_count = try readU32(bytes, &cursor);
            const trie_pair_count = try readU32(bytes, &cursor);
            const trie_bmp_count = try readU32(bytes, &cursor);
            const trie_triple_count = try readU32(bytes, &cursor);
            const trie_base_count = try readU32(bytes, &cursor);
            const trie_check_count = try readU32(bytes, &cursor);
            const trie_child_count = try readU32(bytes, &cursor);

            // Every lookup starts at the root node.
            if (trie_node_count == 0) return error.InvalidDictionary;
            owns_trie_streams = !borrow_binary_tables;
            owns_trie_u32_tables = !borrow_binary_tables;
            trie_nodes = try readStructSlice(TrieNode, allocator, bytes, &cursor, @intCast(trie_node_count), borrow_binary_tables);
            trie_edges = try readStructSlice(TrieEdge, allocator, bytes, &cursor, @intCast(trie_edge_count), borrow_binary_tables);
            trie_terms = try readStructSlice(TrieTerm, allocator, bytes, &cursor, @intCast(trie_term_count), borrow_binary_tables);
            trie_count_terms = try readStructSlice(TrieCountTerm, allocator, bytes, &cursor, @intCast(trie_count_term_count), borrow_binary_tables);
            trie_pair = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_pair_count), borrow_binary_tables);
            trie_bmp = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_bmp_count), borrow_binary_tables);
            trie_triple = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_triple_count), borrow_binary_tables);
            trie_base = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_base_count), borrow_binary_tables);
            trie_check = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_check_count), borrow_binary_tables);
            trie_child = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_child_count), borrow_binary_tables);
        } else {
            // Backward compatibility for DLRDIC01 files. New dictionaries write
            // DLRDIC02 and skip this rebuild path entirely.
            const trie = try buildTrie(allocator, entries, &matrix);
            trie_nodes = trie.nodes;
            trie_edges = trie.edges;
            trie_terms = trie.terms;
            trie_count_terms = trie.count_terms;
            owns_trie_streams = true;
            trie_pair = if (entries.len <= 32) emptyU32Slice() else try buildTriePair(allocator, trie_nodes, trie_edges);
            trie_bmp = if (entries.len <= 32) emptyU32Slice() else try buildTrieBmp(allocator, trie_nodes, trie_edges);
            trie_triple = try buildTrieTriple(allocator, trie_nodes, trie_edges);
            const double_array = try buildDoubleArray(allocator, trie_nodes, trie_edges);
            trie_base = double_array.base;
            trie_check = double_array.check;
            trie_child = double_array.child;
            owns_trie_u32_tables = true;
        }

        if (cursor != bytes.len) return error.InvalidDictionary;

        return .{
            .allocator = allocator,
            .entries = entries,
            .entry_features = entry_features,
            .entry_blob = entry_blob,
            .owns_entry_blob = copy_feature_blob,
            .user_entries = &.{},
            .unk_entries = unk_entries,
            .unk_feature_blob = unk_feature_blob,
            .owns_unk_feature_blob = copy_feature_blob,
            .unk_index = unk_index,
            .char_property = char_property,
            .matrix = matrix,
            .owns_matrix_costs = !borrow_binary_tables,
            .entry_index = entry_index,
            .trie_nodes = trie_nodes,
            .trie_edges = trie_edges,
            .trie_terms = trie_terms,
            .trie_count_terms = trie_count_terms,
            .owns_trie_streams = owns_trie_streams,
            .trie_first = buildTrieFirst(trie_nodes, trie_edges),
            .trie_bmp = trie_bmp,
            .trie_pair = trie_pair,
            .trie_triple = trie_triple,
            .trie_base = trie_base,
            .trie_check = trie_check,
            .trie_child = trie_child,
            .owns_trie_u32_tables = owns_trie_u32_tables,
        };
    }

    pub fn deinit(self: *Dictionary) void {
        self.entry_index.deinit(self.allocator);
        self.unk_index.deinit(self.allocator);
        if (self.owns_trie_streams) {
            freeAlign1Slice(TrieNode, self.allocator, self.trie_nodes);
            freeAlign1Slice(TrieEdge, self.allocator, self.trie_edges);
            freeAlign1Slice(TrieTerm, self.allocator, self.trie_terms);
            freeAlign1Slice(TrieCountTerm, self.allocator, self.trie_count_terms);
        }
        if (self.owns_trie_u32_tables) {
            if (self.trie_bmp.len != 0) freeU32Slice(self.allocator, self.trie_bmp);
            if (self.trie_pair.len != 0) freeU32Slice(self.allocator, self.trie_pair);
            if (self.trie_triple.len != 0) freeU32Slice(self.allocator, self.trie_triple);
            freeDoubleArray(self.allocator, .{ .base = self.trie_base, .check = self.trie_check, .child = self.trie_child });
        }
        if (self.entry_features.len != 0) {
            self.allocator.free(self.entry_features);
            if (self.owns_entry_blob) self.allocator.free(self.entry_blob);
        } else if (self.entry_blob.len != 0) {
            if (self.owns_entry_blob) self.allocator.free(self.entry_blob);
            self.allocator.free(self.entries);
        } else {
            freeEntrySlice(self.allocator, self.entries);
        }
        freeEntrySlice(self.allocator, self.user_entries);
        if (self.unk_feature_blob.len != 0) {
            if (self.owns_unk_feature_blob) self.allocator.free(self.unk_feature_blob);
            self.allocator.free(self.unk_entries);
        } else {
            freeUnkSlice(self.allocator, self.unk_entries);
        }
        self.char_property.deinit();
        if (self.owns_matrix_costs) freeI16Slice(self.allocator, self.matrix.costs);
        if (self.mapped_file) |mapped| mapped.close();
        self.mapped_file = null;
    }

    pub fn discardFullTokenDataForCount(self: *Dictionary) void {
        if (self.trie_pair.len == 0) return;

        // Count-only tokenization walks `trie_count_terms` and the unknown-term
        // index, so full dictionary entries, features, word ids, and full trie
        // terms only add allocator pressure and cache noise for large trie
        // dictionaries. Keep this opt-in so normal tokenization remains intact.
        if (self.entry_features.len != 0) {
            self.allocator.free(self.entry_features);
            self.entry_features = emptyFeatureRefSlice();
            if (self.owns_entry_blob) self.allocator.free(self.entry_blob);
            self.entry_blob = emptyU8Slice();
            self.owns_entry_blob = false;
        } else if (self.entry_blob.len != 0) {
            if (self.owns_entry_blob) self.allocator.free(self.entry_blob);
            self.allocator.free(self.entries);
            self.entry_blob = emptyU8Slice();
            self.owns_entry_blob = false;
        } else {
            freeEntrySlice(self.allocator, self.entries);
        }
        self.entries = emptyEntrySlice();

        freeEntrySlice(self.allocator, self.user_entries);
        self.user_entries = emptyEntrySlice();

        if (self.owns_trie_streams) freeAlign1Slice(TrieTerm, self.allocator, self.trie_terms);
        self.trie_terms = emptyTrieTermSlice();
        if (self.unk_feature_blob.len != 0) {
            if (self.owns_unk_feature_blob) self.allocator.free(self.unk_feature_blob);
            self.allocator.free(self.unk_entries);
            self.unk_feature_blob = emptyU8Slice();
            self.owns_unk_feature_blob = false;
        } else {
            freeUnkSlice(self.allocator, self.unk_entries);
        }
        self.unk_entries = emptyUnkEntrySlice();
    }

    // Rebuild the feature slice only for the final best-path tokens. The hot
    // lattice expansion path does not need known-word feature text.
    pub inline fn entryFeature(self: *const Dictionary, word_id: u32) []const u8 {
        const ref = self.entry_features[word_id];
        const start: usize = @intCast(ref.offset);
        const len: usize = @intCast(ref.len);
        return self.entry_blob[start .. start + len];
    }
};

fn addSizes(initial: usize, values: anytype) !usize {
    var total = initial;
    inline for (values) |value| total = try std.math.add(usize, total, value);
    return total;
}

const BuildTrieNode = struct {
    /// This node's outgoing edges in the shared edge pool, linked in insertion
    /// order through `BuildTrieEdge.next`.
    first_edge: u32 = invalid_trie_node,
    last_edge: u32 = invalid_trie_node,
    edge_len: u32 = 0,
    word_len: u32 = 0,
    /// Index of a 256-entry child table in the dense pool once the node has
    /// `build_trie_dense_threshold` edges; lookups then skip the list walk.
    dense: u32 = invalid_trie_node,
};

const build_trie_dense_threshold = 8;

const BuildTrieEdge = struct {
    child: u32,
    next: u32,
    byte: u8,
};

const TrieBuildResult = struct {
    nodes: []TrieNode,
    edges: []TrieEdge,
    terms: []TrieTerm,
    count_terms: []TrieCountTerm,
};

pub const DoubleArray = struct {
    base: []align(1) const u32,
    check: []align(1) const u32,
    child: []align(1) const u32,
};

pub const invalid_trie_node: u32 = std.math.maxInt(u32);

fn buildUnkIndex(allocator: Allocator, category_count: usize, entries: []const UnkEntry, matrix: *const ConnectionMatrix) !UnkIndex {
    var lists = try allocator.alloc(std.ArrayList(UnkTerm), category_count);
    defer allocator.free(lists);
    for (lists) |*list| list.* = .empty;
    defer {
        for (lists) |*list| list.deinit(allocator);
    }

    for (entries, 0..) |entry, unk_id| {
        if (entry.category_id >= category_count) return error.InvalidDictionary;
        try lists[entry.category_id].append(allocator, .{
            .unk_id = @intCast(unk_id),
            .left_id = entry.left_id,
            .right_id = entry.right_id,
            .word_cost = entry.word_cost,
        });
    }

    const buckets = try allocator.alloc([]UnkTerm, category_count);
    errdefer allocator.free(buckets);
    const count_buckets = try allocator.alloc([]UnkTerm, category_count);
    errdefer allocator.free(count_buckets);
    const fallback_terms = try allocator.alloc(UnkTerm, category_count);
    errdefer allocator.free(fallback_terms);

    for (lists, 0..) |*list, category_id| {
        buckets[category_id] = try list.toOwnedSlice(allocator);
        var count_terms: std.ArrayList(UnkTerm) = .empty;
        defer count_terms.deinit(allocator);
        for (buckets[category_id]) |term| {
            try appendUnkCountTerm(allocator, &count_terms, term, matrix);
        }
        count_buckets[category_id] = try count_terms.toOwnedSlice(allocator);
        fallback_terms[category_id] = if (buckets[category_id].len == 0)
            .{ .unk_id = 0, .left_id = entries[0].left_id, .right_id = entries[0].right_id, .word_cost = entries[0].word_cost }
        else
            buckets[category_id][0];
    }

    return .{ .buckets = buckets, .count_buckets = count_buckets, .fallback_terms = fallback_terms };
}

fn appendUnkCountTerm(allocator: Allocator, terms: *std.ArrayList(UnkTerm), candidate: UnkTerm, matrix: *const ConnectionMatrix) !void {
    // Count-only unknown terms for one category emit the same spans. If two
    // candidates also emit the same right id, the one that is no cheaper from
    // any predecessor right id cannot change the best path or token count.
    var index: usize = 0;
    while (index < terms.items.len) {
        const existing = &terms.items[index];
        if (existing.right_id == candidate.right_id) {
            if (existing.left_id == candidate.left_id) {
                if (candidate.word_cost < existing.word_cost) existing.* = candidate;
                return;
            }
            if (unkTermDominates(matrix, existing.*, candidate)) return;
            if (unkTermDominates(matrix, candidate, existing.*)) {
                _ = terms.swapRemove(index);
                continue;
            }
        }
        index += 1;
    }
    try terms.append(allocator, candidate);
}

fn unkTermDominates(matrix: *const ConnectionMatrix, lhs: UnkTerm, rhs: UnkTerm) bool {
    var prev_right: usize = 0;
    while (prev_right < matrix.right_size) : (prev_right += 1) {
        const lhs_cost = @as(i32, matrix.costs[@as(usize, lhs.left_id) * matrix.right_size + prev_right]) + lhs.word_cost;
        const rhs_cost = @as(i32, matrix.costs[@as(usize, rhs.left_id) * matrix.right_size + prev_right]) + rhs.word_cost;
        if (lhs_cost > rhs_cost) return false;
    }
    return true;
}

fn buildEntryIndex(allocator: Allocator, entries: []const Entry) !EntryIndex {
    var lists: [256]std.ArrayList(u32) = undefined;
    for (&lists) |*list| list.* = .empty;
    defer {
        for (&lists) |*list| list.deinit(allocator);
    }

    for (entries, 0..) |entry, word_id| {
        if (entry.surface.len == 0) continue;
        try lists[entry.surface[0]].append(allocator, @intCast(word_id));
    }

    var index = EntryIndex.empty();
    errdefer index.deinit(allocator);
    for (&lists, 0..) |*list, i| {
        index.buckets[i] = try list.toOwnedSlice(allocator);
    }
    return index;
}

fn buildTrie(allocator: Allocator, entries: []const Entry, matrix: *const ConnectionMatrix) !TrieBuildResult {
    // Nodes and edges live in two flat pools (no per-node allocations); each
    // node's edges form a linked list in insertion order. `word_nodes[i]` is
    // the terminal node of entries[i], later grouped per node by a stable
    // counting sort so each node's terms keep ascending word id order.
    var build_nodes: std.ArrayList(BuildTrieNode) = .empty;
    defer build_nodes.deinit(allocator);
    var build_edges: std.ArrayList(BuildTrieEdge) = .empty;
    defer build_edges.deinit(allocator);
    var dense_children: std.ArrayList(u32) = .empty;
    defer dense_children.deinit(allocator);
    const word_nodes = try allocator.alloc(u32, entries.len);
    defer allocator.free(word_nodes);

    try build_nodes.append(allocator, .{});
    for (entries, 0..) |entry, word_id| {
        var node_index: usize = 0;
        for (entry.surface) |byte| {
            const node = build_nodes.items[node_index];
            const found = if (node.dense != invalid_trie_node)
                dense_children.items[@as(usize, node.dense) * 256 + byte]
            else
                findBuildEdge(build_edges.items, node.first_edge, byte);
            if (found != invalid_trie_node) {
                node_index = found;
            } else {
                const child: u32 = @intCast(build_nodes.items.len);
                try build_nodes.append(allocator, .{});
                const edge_index: u32 = @intCast(build_edges.items.len);
                try build_edges.append(allocator, .{ .byte = byte, .child = child, .next = invalid_trie_node });
                const parent = &build_nodes.items[node_index];
                if (parent.last_edge == invalid_trie_node) {
                    parent.first_edge = edge_index;
                } else {
                    build_edges.items[parent.last_edge].next = edge_index;
                }
                parent.last_edge = edge_index;
                parent.edge_len += 1;
                if (parent.dense != invalid_trie_node) {
                    dense_children.items[@as(usize, parent.dense) * 256 + byte] = child;
                } else if (parent.edge_len == build_trie_dense_threshold) {
                    parent.dense = @intCast(dense_children.items.len / 256);
                    const table = try dense_children.addManyAsArray(allocator, 256);
                    @memset(table, invalid_trie_node);
                    var e = parent.first_edge;
                    while (e != invalid_trie_node) : (e = build_edges.items[e].next) {
                        table[build_edges.items[e].byte] = build_edges.items[e].child;
                    }
                }
                node_index = child;
            }
        }
        build_nodes.items[node_index].word_len += 1;
        word_nodes[word_id] = @intCast(node_index);
    }

    const nodes = try allocator.alloc(TrieNode, build_nodes.items.len);
    errdefer allocator.free(nodes);
    const edges = try allocator.alloc(TrieEdge, build_edges.items.len);
    errdefer allocator.free(edges);
    const terms = try allocator.alloc(TrieTerm, entries.len);
    errdefer allocator.free(terms);
    var count_terms: std.ArrayList(TrieCountTerm) = .empty;
    errdefer count_terms.deinit(allocator);

    // word_starts[i] = offset of node i's first term.
    const word_starts = try allocator.alloc(u32, build_nodes.items.len);
    defer allocator.free(word_starts);
    {
        var offset: usize = 0;
        for (build_nodes.items, word_starts) |node, *word_start| {
            word_start.* = try narrowTrieOffset(offset);
            offset += node.word_len;
        }
        const cursor = try allocator.dupe(u32, word_starts);
        defer allocator.free(cursor);
        for (word_nodes, 0..) |node_index, word_id| {
            const entry = entries[word_id];
            terms[cursor[node_index]] = .{
                .word_id = @intCast(word_id),
                .left_id = entry.left_id,
                .right_id = entry.right_id,
                .word_cost = entry.word_cost,
            };
            cursor[node_index] += 1;
        }
    }

    var edge_offset: usize = 0;
    for (build_nodes.items, 0..) |node, i| {
        const node_edges = edges[edge_offset .. edge_offset + node.edge_len];
        var edge_index = node.first_edge;
        for (node_edges) |*edge| {
            const build_edge = build_edges.items[edge_index];
            edge.* = .{ .byte = build_edge.byte, .child = build_edge.child };
            edge_index = build_edge.next;
        }
        std.mem.sort(TrieEdge, node_edges, {}, trieEdgeLessThan);

        const word_offset: usize = word_starts[i];
        const count_start = count_terms.items.len;
        for (terms[word_offset .. word_offset + node.word_len]) |term| {
            try appendCountTerm(allocator, &count_terms, term, count_start, matrix);
        }
        nodes[i] = .{
            .edge_start = try narrowTrieOffset(edge_offset),
            .edge_len = @intCast(node.edge_len),
            .word_start = try narrowTrieOffset(word_offset),
            .word_len = try narrowTrieTermLen(node.word_len),
            .count_word_start = try narrowTrieOffset(count_start),
            .count_word_len = try narrowTrieTermLen(count_terms.items.len - count_start),
        };
        edge_offset += node.edge_len;
    }

    return .{ .nodes = nodes, .edges = edges, .terms = terms, .count_terms = try count_terms.toOwnedSlice(allocator) };
}

fn appendCountTerm(allocator: Allocator, terms: *std.ArrayList(TrieCountTerm), term: TrieTerm, start: usize, matrix: *const ConnectionMatrix) !void {
    // Multiple entries can share the same left/right ids at one trie node. For
    // count-only tokenization those entries are equivalent except for word
    // cost, so retain only the cheapest transition.
    const candidate: TrieCountTerm = .{
        .left_id = term.left_id,
        .right_id = term.right_id,
        .word_cost = term.word_cost,
    };
    var index = start;
    while (index < terms.items.len) {
        const existing = &terms.items[index];
        if (existing.right_id == candidate.right_id) {
            if (existing.left_id == candidate.left_id) {
                if (candidate.word_cost < existing.word_cost) existing.word_cost = candidate.word_cost;
                return;
            }
            // For the same emitted right id, a term that is no cheaper from any
            // predecessor right id can never be part of the best count-only
            // path. Paying this O(matrix.right_size) check during dictionary
            // build reduces candidate traffic in the tokenizer hot path.
            if (countTermDominates(matrix, existing.*, candidate)) return;
            if (countTermDominates(matrix, candidate, existing.*)) {
                _ = terms.swapRemove(index);
                continue;
            }
        }
        index += 1;
    }
    try terms.append(allocator, candidate);
}

fn countTermDominates(matrix: *const ConnectionMatrix, lhs: TrieCountTerm, rhs: TrieCountTerm) bool {
    var prev_right: usize = 0;
    while (prev_right < matrix.right_size) : (prev_right += 1) {
        const lhs_cost = @as(i32, matrix.costs[@as(usize, lhs.left_id) * matrix.right_size + prev_right]) + lhs.word_cost;
        const rhs_cost = @as(i32, matrix.costs[@as(usize, rhs.left_id) * matrix.right_size + prev_right]) + rhs.word_cost;
        if (lhs_cost > rhs_cost) return false;
    }
    return true;
}

fn findBuildEdge(edges: []const BuildTrieEdge, first_edge: u32, byte: u8) u32 {
    var edge_index = first_edge;
    while (edge_index != invalid_trie_node) {
        const edge = edges[edge_index];
        if (edge.byte == byte) return edge.child;
        edge_index = edge.next;
    }
    return invalid_trie_node;
}

fn buildTrieFirst(nodes: []const TrieNode, edges: []const TrieEdge) [256]u32 {
    var first: [256]u32 = [_]u32{invalid_trie_node} ** 256;
    const root = nodes[0];
    const start: usize = @intCast(root.edge_start);
    const len: usize = @intCast(root.edge_len);
    for (edges[start .. start + len]) |edge| {
        first[edge.byte] = edge.child;
    }
    return first;
}

fn buildTriePair(allocator: Allocator, nodes: []const TrieNode, edges: []const TrieEdge) ![]align(1) const u32 {
    // The dense two-byte root table is small enough (256 KiB) to be worth it:
    // it skips two levels of root traversal for UTF-8-heavy Japanese input and
    // still fits comfortably in cache compared with the rejected triple table.
    const pair = try allocator.alloc(u32, 256 * 256);
    @memset(pair, invalid_trie_node);
    const root = nodes[0];
    const root_start: usize = @intCast(root.edge_start);
    const root_len: usize = @intCast(root.edge_len);
    for (edges[root_start .. root_start + root_len]) |first| {
        const child = nodes[@intCast(first.child)];
        const child_start: usize = @intCast(child.edge_start);
        const child_len: usize = @intCast(child.edge_len);
        for (edges[child_start .. child_start + child_len]) |second| {
            pair[(@as(usize, first.byte) << 8) | @as(usize, second.byte)] = second.child;
        }
    }
    return pair;
}

fn buildTrieBmp(allocator: Allocator, nodes: []const TrieNode, edges: []const TrieEdge) ![]align(1) const u32 {
    // Most Japanese dictionary surfaces start with one BMP codepoint encoded as
    // three UTF-8 bytes. This table jumps directly from that first codepoint to
    // the trie node for 256 KiB, avoiding the 64 MiB cost of a dense raw 3-byte
    // table while still removing the extra root traversal from the hot path.
    const bmp = try allocator.alloc(u32, 0x10000);
    @memset(bmp, invalid_trie_node);

    const root = nodes[0];
    const root_start: usize = @intCast(root.edge_start);
    const root_len: usize = @intCast(root.edge_len);
    for (edges[root_start .. root_start + root_len]) |first| {
        if (first.byte >= 0xc2 and first.byte <= 0xdf) {
            const child = nodes[@intCast(first.child)];
            const child_start: usize = @intCast(child.edge_start);
            const child_len: usize = @intCast(child.edge_len);
            for (edges[child_start .. child_start + child_len]) |second| {
                if (!isUtf8Continuation(second.byte)) continue;
                const cp = (@as(u32, first.byte & 0x1f) << 6) | @as(u32, second.byte & 0x3f);
                bmp[cp] = second.child;
            }
        } else if (first.byte >= 0xe0 and first.byte <= 0xef) {
            const child = nodes[@intCast(first.child)];
            const child_start: usize = @intCast(child.edge_start);
            const child_len: usize = @intCast(child.edge_len);
            for (edges[child_start .. child_start + child_len]) |second| {
                if (!isUtf8Continuation(second.byte)) continue;
                const grandchild = nodes[@intCast(second.child)];
                const grandchild_start: usize = @intCast(grandchild.edge_start);
                const grandchild_len: usize = @intCast(grandchild.edge_len);
                for (edges[grandchild_start .. grandchild_start + grandchild_len]) |third| {
                    if (!isUtf8Continuation(third.byte)) continue;
                    const cp = (@as(u32, first.byte & 0x0f) << 12) | (@as(u32, second.byte & 0x3f) << 6) | @as(u32, third.byte & 0x3f);
                    if (cp >= 0xd800 and cp <= 0xdfff) continue;
                    bmp[cp] = third.child;
                }
            }
        }
    }
    return bmp;
}

fn buildTrieTriple(allocator: Allocator, nodes: []const TrieNode, edges: []const TrieEdge) ![]align(1) const u32 {
    _ = allocator;
    _ = nodes;
    _ = edges;
    // A dense 3-byte table costs 64 MiB and regresses ipadic tokenization by
    // pushing the hot dictionary data out of cache. Pair lookup plus the
    // double-array fallback is the better default for large dictionaries.
    return emptyU32Slice();
}

inline fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

fn buildDoubleArray(allocator: Allocator, nodes: []const TrieNode, edges: []const TrieEdge) !DoubleArray {
    if (nodes.len < 65536) return .{ .base = &.{}, .check = &.{}, .child = &.{} };

    // The double-array is only built for large dictionaries. Disabling it saves
    // memory but regresses ipadic binary tokenization heavily, so it remains the
    // fallback after the root pair table.
    const base = try allocator.alloc(u32, nodes.len);
    errdefer allocator.free(base);
    @memset(base, 0);

    const order = try allocator.alloc(usize, nodes.len);
    defer allocator.free(order);
    for (order, 0..) |*item, i| item.* = i;
    std.mem.sort(usize, order, nodes, trieNodeFanoutGreater);

    // `free` is a bitmap over double-array slots (bit set = slot unused).
    // Slots past its end are implicitly free. Searching for a base value then
    // tests 64 consecutive candidates per word: AND-ing the free bits at each
    // edge's offset yields the candidates where every edge slot is free, and
    // @ctz picks the smallest. This finds exactly the same base as a linear
    // candidate-by-candidate scan, so the layout is unchanged.
    var free: DoubleArrayFreeBits = .{};
    defer free.deinit(allocator);
    var check: std.ArrayList(u32) = .empty;
    errdefer check.deinit(allocator);
    var child: std.ArrayList(u32) = .empty;
    errdefer child.deinit(allocator);

    try ensureDoubleArrayCapacity(allocator, &free, &check, &child, 512);
    var next_free: usize = 1;
    for (order) |node_index| {
        const node = nodes[node_index];
        const edge_len: usize = @intCast(node.edge_len);
        // Three-way and larger branches are faster through the double-array
        // probe than through per-node binary search on ipadic hot paths. One-
        // and two-way branches stay in the compact edge slice to avoid the
        // memory blow-up that regressed the count-only benchmark.
        if (edge_len < 3) continue;
        const edge_start: usize = @intCast(node.edge_start);
        const node_edges = edges[edge_start .. edge_start + edge_len];
        const first_byte: usize = node_edges[0].byte;
        const candidate = free.findBase(node_edges, if (next_free > first_byte) next_free - first_byte else 1);

        var max_slot: usize = 0;
        for (node_edges) |edge| max_slot = @max(max_slot, candidate + edge.byte);
        try ensureDoubleArrayCapacity(allocator, &free, &check, &child, max_slot + 1);

        base[node_index] = @intCast(candidate);
        for (node_edges) |edge| {
            const slot = candidate + edge.byte;
            free.markUsed(slot);
            check.items[slot] = @intCast(node_index);
            child.items[slot] = edge.child;
        }
        next_free = @min(free.nextFree(next_free), check.items.len);
    }

    return .{
        .base = base,
        .check = try check.toOwnedSlice(allocator),
        .child = try child.toOwnedSlice(allocator),
    };
}

fn trieNodeFanoutGreater(nodes: []const TrieNode, lhs: usize, rhs: usize) bool {
    return nodes[lhs].edge_len > nodes[rhs].edge_len;
}

fn narrowTrieTermLen(len: usize) !u32 {
    return std.math.cast(u32, len) orelse error.InvalidDictionary;
}

fn narrowTrieOffset(offset: usize) !u32 {
    return std.math.cast(u32, offset) orelse error.InvalidDictionary;
}

const DoubleArrayFreeBits = struct {
    /// Bit set = slot free. The slice always extends `padding_words` all-ones
    /// words past the double-array length so that windows starting at any
    /// candidate <= length plus any edge byte stay in bounds without checks.
    words: std.ArrayList(u64) = .empty,

    // A window reads `lanes + 1` words starting at most (length + 255) / 64,
    // i.e. up to word length / 64 + 4 + lanes.
    const padding_words = 16;

    fn deinit(self: *DoubleArrayFreeBits, allocator: Allocator) void {
        self.words.deinit(allocator);
    }

    fn grow(self: *DoubleArrayFreeBits, allocator: Allocator, slot_len: usize) !void {
        std.debug.assert(slot_len % 64 == 0);
        const target = slot_len / 64 + padding_words;
        if (self.words.items.len < target) {
            try self.words.appendNTimes(allocator, ~@as(u64, 0), target - self.words.items.len);
        }
    }

    const lanes = 8;
    const Lanes = @Vector(lanes, u64);

    /// Free bits for slots [bit, bit + 64 * lanes): lane k bit j = slot
    /// bit + 64 * k + j.
    inline fn window(words: []const u64, bit: usize) Lanes {
        const index = bit >> 6;
        const shift: u6 = @truncate(bit);
        const lo: Lanes = words[index..][0..lanes].*;
        const hi: Lanes = words[index + 1 ..][0..lanes].*;
        // `(hi << 1) << (63 - shift)` is `hi << (64 - shift)` without the
        // undefined shift-by-64 when shift == 0.
        const s: @Vector(lanes, u6) = @splat(shift);
        const t: @Vector(lanes, u6) = @splat(63 - shift);
        const one: @Vector(lanes, u6) = @splat(1);
        return (lo >> s) | ((hi << one) << t);
    }

    /// Smallest base >= start such that base + edge.byte is free for every
    /// edge. `start` must not exceed the double-array length, which bounds the
    /// search: a base equal to the length always fits. Candidates are tested
    /// 64 * lanes at a time; the result equals a linear candidate scan.
    fn findBase(self: *const DoubleArrayFreeBits, node_edges: []const TrieEdge, start: usize) usize {
        const words = self.words.items;
        var chunk = start;
        while (true) : (chunk += 64 * lanes) {
            var mask: Lanes = @splat(~@as(u64, 0));
            for (node_edges) |edge| {
                mask &= window(words, chunk + edge.byte);
                if (@reduce(.Or, mask) == 0) break;
            }
            if (@reduce(.Or, mask) == 0) continue;
            const arr: [lanes]u64 = mask;
            for (arr, 0..) |bits, k| {
                if (bits != 0) return chunk + 64 * k + @ctz(bits);
            }
            unreachable;
        }
    }

    /// Smallest free slot >= start. Terminates in the all-ones padding.
    fn nextFree(self: *const DoubleArrayFreeBits, start: usize) usize {
        const words = self.words.items;
        var index = start >> 6;
        var bits = words[index] & (~@as(u64, 0) << @as(u6, @truncate(start)));
        while (bits == 0) {
            index += 1;
            bits = words[index];
        }
        return index * 64 + @ctz(bits);
    }

    inline fn markUsed(self: *DoubleArrayFreeBits, slot: usize) void {
        self.words.items[slot >> 6] &= ~(@as(u64, 1) << @as(u6, @truncate(slot)));
    }
};

fn ensureDoubleArrayCapacity(
    allocator: Allocator,
    free: *DoubleArrayFreeBits,
    check: *std.ArrayList(u32),
    child: *std.ArrayList(u32),
    required: usize,
) !void {
    if (check.items.len >= required) return;
    var new_len = @max(check.items.len, @as(usize, 512));
    while (new_len < required) new_len *= 2;

    const old_len = check.items.len;
    try check.resize(allocator, new_len);
    try child.resize(allocator, new_len);
    @memset(check.items[old_len..], invalid_trie_node);
    @memset(child.items[old_len..], invalid_trie_node);
    // new_len is a multiple of 64 (512 doubled).
    try free.grow(allocator, new_len);
}

fn freeDoubleArray(allocator: Allocator, double_array: DoubleArray) void {
    if (double_array.base.len != 0) freeU32Slice(allocator, double_array.base);
    if (double_array.check.len != 0) freeU32Slice(allocator, double_array.check);
    if (double_array.child.len != 0) freeU32Slice(allocator, double_array.child);
}

pub inline fn findEdge(nodes: []const TrieNode, edges: []const TrieEdge, node_index: usize, byte: u8) ?usize {
    const node = nodes[node_index];
    const start: usize = @intCast(node.edge_start);
    const len: usize = @intCast(node.edge_len);
    const node_edges = edges[start .. start + len];
    if (node_edges.len <= 2) {
        for (node_edges) |edge| {
            if (edge.byte == byte) return @intCast(edge.child);
        }
        return null;
    }
    var low: usize = 0;
    var high = node_edges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const edge = node_edges[mid];
        if (edge.byte == byte) return @intCast(edge.child);
        if (edge.byte < byte) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return null;
}

fn emptyU32Slice() []align(1) const u32 {
    return @constCast(&[_]u32{});
}

fn emptyI16Slice() []align(1) const i16 {
    return @constCast(&[_]i16{});
}

fn emptyU8Slice() []u8 {
    return @constCast(&[_]u8{});
}

fn emptyEntrySlice() []Entry {
    return @constCast(&[_]Entry{});
}

fn emptyFeatureRefSlice() []FeatureRef {
    return @constCast(&[_]FeatureRef{});
}

fn emptyUnkEntrySlice() []UnkEntry {
    return @constCast(&[_]UnkEntry{});
}

fn emptyTrieTermSlice() []TrieTerm {
    return @constCast(&[_]TrieTerm{});
}

pub inline fn findDoubleArray(base: []align(1) const u32, check: []align(1) const u32, child: []align(1) const u32, node_index: usize, byte: u8) ?usize {
    if (base.len == 0) return null;
    const node_base = base[node_index];
    if (node_base == 0) return null;
    const slot = @as(usize, node_base) + byte;
    if (slot >= check.len or check[slot] != node_index) return null;
    return @intCast(child[slot]);
}

pub inline fn trieTerms(nodes: []const TrieNode, trie_terms: []align(1) const TrieTerm, node_index: usize) []align(1) const TrieTerm {
    const node = nodes[node_index];
    const start: usize = @intCast(node.word_start);
    const len: usize = @intCast(node.word_len);
    return trie_terms[start .. start + len];
}

pub inline fn trieCountTerms(nodes: []const TrieNode, trie_terms: []align(1) const TrieCountTerm, node_index: usize) []align(1) const TrieCountTerm {
    const node = nodes[node_index];
    const start: usize = @intCast(node.count_word_start);
    const len: usize = @intCast(node.count_word_len);
    return trie_terms[start .. start + len];
}

fn trieEdgeLessThan(_: void, lhs: TrieEdge, rhs: TrieEdge) bool {
    return lhs.byte < rhs.byte;
}

fn freeTrie(allocator: Allocator, nodes: []const TrieNode, edges: []const TrieEdge, terms_slice: []align(1) const TrieTerm, count_terms_slice: []align(1) const TrieCountTerm) void {
    freeAlign1Slice(TrieNode, allocator, nodes);
    freeAlign1Slice(TrieEdge, allocator, edges);
    freeAlign1Slice(TrieTerm, allocator, terms_slice);
    freeAlign1Slice(TrieCountTerm, allocator, count_terms_slice);
}

// Frees an allocator-owned slice that is stored behind an align(1) pointer so
// it can share a field with slices borrowed from binary dictionary bytes.
fn freeAlign1Slice(comptime T: type, allocator: Allocator, values: []align(1) const T) void {
    const aligned: []const T = @alignCast(values);
    allocator.free(@constCast(aligned));
}

fn freeU32Slice(allocator: Allocator, values: []align(1) const u32) void {
    const aligned: []const u32 = @alignCast(values);
    allocator.free(@constCast(aligned));
}

fn freeI16Slice(allocator: Allocator, values: []align(1) const i16) void {
    const aligned: []const i16 = @alignCast(values);
    allocator.free(@constCast(aligned));
}

/// A read-only, private memory mapping of a whole file.
pub const MappedFile = struct {
    bytes: []align(std.heap.page_size_min) const u8,

    /// Windows and WASM fall back to reading the file into memory.
    pub const supported = !builtin.cpu.arch.isWasm() and builtin.os.tag != .windows;

    pub fn open(allocator: Allocator, path: []const u8) !MappedFile {
        if (comptime !supported) @compileError("memory-mapped files are not supported on this target");
        var io_instance: std.Io.Threaded = .init(allocator, .{});
        defer io_instance.deinit();
        const io = io_instance.io();
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        // The mapping keeps its own reference to the file; the descriptor is
        // not needed after mmap returns.
        defer file.close(io);
        const len = std.math.cast(usize, try file.length(io)) orelse return error.FileTooBig;
        // mmap rejects zero-length mappings; an empty file is never a valid
        // dictionary anyway.
        if (len == 0) return error.InvalidDictionary;
        const bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
        return .{ .bytes = bytes };
    }

    pub fn close(self: MappedFile) void {
        if (comptime supported) std.posix.munmap(self.bytes);
    }
};

pub fn readFileAlloc(allocator: Allocator, path: []const u8) ![]u8 {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    return std.Io.Dir.cwd().readFileAlloc(io_instance.io(), path, allocator, .limited(256 * 1024 * 1024));
}

fn appendU8(allocator: Allocator, bytes: *std.ArrayList(u8), value: u8) !void {
    try bytes.append(allocator, value);
}

fn appendU16(allocator: Allocator, bytes: *std.ArrayList(u8), value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try bytes.appendSlice(allocator, &buf);
}

fn appendI16(allocator: Allocator, bytes: *std.ArrayList(u8), value: i16) !void {
    try appendU16(allocator, bytes, @bitCast(value));
}

fn appendU32(allocator: Allocator, bytes: *std.ArrayList(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try bytes.appendSlice(allocator, &buf);
}

fn appendI32(allocator: Allocator, bytes: *std.ArrayList(u8), value: i32) !void {
    try appendU32(allocator, bytes, @bitCast(value));
}

fn appendI16Slice(allocator: Allocator, bytes: *std.ArrayList(u8), values: []align(1) const i16) !void {
    if (builtin.cpu.arch.endian() == .little) {
        try bytes.appendSlice(allocator, std.mem.sliceAsBytes(values));
        return;
    }
    for (values) |value| try appendI16(allocator, bytes, value);
}

fn appendU32Slice(allocator: Allocator, bytes: *std.ArrayList(u8), values: []align(1) const u32) !void {
    if (builtin.cpu.arch.endian() == .little) {
        try bytes.appendSlice(allocator, std.mem.sliceAsBytes(values));
        return;
    }
    for (values) |value| try appendU32(allocator, bytes, value);
}

fn appendNativeStructSlice(comptime T: type, allocator: Allocator, bytes: *std.ArrayList(u8), values: []align(1) const T) !void {
    if (builtin.cpu.arch.endian() == .little) {
        try bytes.appendSlice(allocator, std.mem.sliceAsBytes(values));
        return;
    }
    if (T == TrieNode) {
        for (values) |node| {
            try appendU32(allocator, bytes, node.edge_start);
            try appendU16(allocator, bytes, node.edge_len);
            try appendU32(allocator, bytes, node.word_start);
            try appendU32(allocator, bytes, node.word_len);
            try appendU32(allocator, bytes, node.count_word_start);
            try appendU32(allocator, bytes, node.count_word_len);
        }
    } else if (T == TrieEdge) {
        for (values) |edge| {
            try appendU8(allocator, bytes, edge.byte);
            try appendU32(allocator, bytes, edge.child);
        }
    } else if (T == TrieTerm) {
        for (values) |term| {
            try appendU32(allocator, bytes, term.word_id);
            try appendI32(allocator, bytes, term.word_cost);
            try appendU16(allocator, bytes, term.left_id);
            try appendU16(allocator, bytes, term.right_id);
        }
    } else if (T == TrieCountTerm) {
        for (values) |term| {
            try appendI32(allocator, bytes, term.word_cost);
            try appendU16(allocator, bytes, term.left_id);
            try appendU16(allocator, bytes, term.right_id);
        }
    }
}

fn readSlice(bytes: []const u8, cursor: *usize, len: usize) ![]const u8 {
    if (bytes.len - cursor.* < len) return error.InvalidDictionary;
    const start = cursor.*;
    cursor.* += len;
    return bytes[start..cursor.*];
}

fn readU8(bytes: []const u8, cursor: *usize) !u8 {
    return (try readSlice(bytes, cursor, 1))[0];
}

fn readU16(bytes: []const u8, cursor: *usize) !u16 {
    const raw = try readSlice(bytes, cursor, 2);
    return @as(u16, raw[0]) | (@as(u16, raw[1]) << 8);
}

fn readI16(bytes: []const u8, cursor: *usize) !i16 {
    return @bitCast(try readU16(bytes, cursor));
}

fn readI16Slice(allocator: Allocator, bytes: []const u8, cursor: *usize, count: usize, borrow: bool) ![]align(1) const i16 {
    if (count == 0) return emptyI16Slice();
    const raw = try readSlice(bytes, cursor, try std.math.mul(usize, count, 2));
    if (borrow) {
        return std.mem.bytesAsSlice(i16, raw);
    }
    const values = try allocator.alloc(i16, count);
    errdefer allocator.free(values);
    if (builtin.cpu.arch.endian() == .little) {
        @memcpy(std.mem.sliceAsBytes(values), raw);
    } else {
        var raw_cursor: usize = 0;
        for (values) |*value| value.* = try readI16(raw, &raw_cursor);
    }
    return values;
}

fn readU32(bytes: []const u8, cursor: *usize) !u32 {
    const raw = try readSlice(bytes, cursor, 4);
    return @as(u32, raw[0]) |
        (@as(u32, raw[1]) << 8) |
        (@as(u32, raw[2]) << 16) |
        (@as(u32, raw[3]) << 24);
}

fn readI32(bytes: []const u8, cursor: *usize) !i32 {
    return @bitCast(try readU32(bytes, cursor));
}

// Reads a stream of fixed-layout records. On little-endian targets the file
// layout equals the in-memory `extern struct` layout, so `borrow` returns a
// view into `bytes` without touching the data; otherwise the records are
// copied (or decoded field by field on big-endian targets).
fn readStructSlice(comptime T: type, allocator: Allocator, bytes: []const u8, cursor: *usize, count: usize, borrow: bool) ![]align(1) const T {
    comptime std.debug.assert(@typeInfo(T).@"struct".layout == .@"extern");
    const raw = try readSlice(bytes, cursor, try std.math.mul(usize, count, @sizeOf(T)));
    if (borrow and builtin.cpu.arch.endian() == .little) return std.mem.bytesAsSlice(T, raw);
    const values = try allocator.alloc(T, count);
    errdefer allocator.free(values);
    if (builtin.cpu.arch.endian() == .little) {
        @memcpy(std.mem.sliceAsBytes(values), raw);
        return values;
    }
    var raw_cursor: usize = 0;
    for (values) |*value| {
        value.* = switch (T) {
            TrieNode => .{
                .edge_start = try readU32(raw, &raw_cursor),
                .edge_len = try readU16(raw, &raw_cursor),
                .word_start = try readU32(raw, &raw_cursor),
                .word_len = try readU32(raw, &raw_cursor),
                .count_word_start = try readU32(raw, &raw_cursor),
                .count_word_len = try readU32(raw, &raw_cursor),
            },
            TrieEdge => .{
                .byte = try readU8(raw, &raw_cursor),
                .child = try readU32(raw, &raw_cursor),
            },
            TrieTerm => .{
                .word_id = try readU32(raw, &raw_cursor),
                .word_cost = try readI32(raw, &raw_cursor),
                .left_id = try readU16(raw, &raw_cursor),
                .right_id = try readU16(raw, &raw_cursor),
            },
            TrieCountTerm => .{
                .word_cost = try readI32(raw, &raw_cursor),
                .left_id = try readU16(raw, &raw_cursor),
                .right_id = try readU16(raw, &raw_cursor),
            },
            else => @compileError("unsupported binary record type"),
        };
    }
    return values;
}

// Reads the fixed 16-byte header of a binary lexicon entry (surface_len u32,
// left_id u16, right_id u16, word_cost i32, feature_len u32), checks that the
// surface and feature bytes that follow are in bounds, and leaves `cursor` at
// the start of the surface bytes.
inline fn readBinaryEntryLens(bytes: []const u8, cursor: *usize) !struct { usize, usize } {
    const start = cursor.*;
    if (bytes.len - start < 16) return error.InvalidDictionary;
    const header = bytes[start..][0..16];
    const surface_len: usize = std.mem.readInt(u32, header[0..4], .little);
    const feature_len: usize = std.mem.readInt(u32, header[12..16], .little);
    const body = start + 16;
    if (bytes.len - body < surface_len or bytes.len - body - surface_len < feature_len) return error.InvalidDictionary;
    cursor.* = body;
    return .{ surface_len, feature_len };
}

fn readU32Slice(allocator: Allocator, bytes: []const u8, cursor: *usize, count: usize, borrow: bool) ![]align(1) const u32 {
    if (count == 0) return emptyU32Slice();
    const raw = try readSlice(bytes, cursor, try std.math.mul(usize, count, 4));
    if (borrow) {
        return std.mem.bytesAsSlice(u32, raw);
    }
    const values = try allocator.alloc(u32, count);
    errdefer allocator.free(values);
    if (builtin.cpu.arch.endian() == .little) {
        @memcpy(std.mem.sliceAsBytes(values), raw);
    } else {
        var raw_cursor: usize = 0;
        for (values) |*value| value.* = try readU32(raw, &raw_cursor);
    }
    return values;
}

fn scanBinaryEntryBlobLen(bytes: []const u8, start_cursor: usize, entry_count: usize) !usize {
    var cursor = start_cursor;
    var total: usize = 0;
    for (0..entry_count) |_| {
        const surface_len: usize = @intCast(try readU32(bytes, &cursor));
        _ = try readU16(bytes, &cursor);
        _ = try readU16(bytes, &cursor);
        _ = try readI32(bytes, &cursor);
        const feature_len: usize = @intCast(try readU32(bytes, &cursor));
        total = try std.math.add(usize, total, surface_len);
        total = try std.math.add(usize, total, feature_len);
        _ = try readSlice(bytes, &cursor, surface_len);
        _ = try readSlice(bytes, &cursor, feature_len);
    }
    return total;
}

fn scanBinaryEntryFeatureBlobLen(bytes: []const u8, start_cursor: usize, entry_count: usize) !usize {
    var cursor = start_cursor;
    var total: usize = 0;
    for (0..entry_count) |_| {
        const surface_len, const feature_len = try readBinaryEntryLens(bytes, &cursor);
        cursor += surface_len + feature_len;
        // Feature bytes are in bounds of `bytes`, so the sum cannot overflow.
        total += feature_len;
    }
    return total;
}

fn scanBinaryUnkFeatureBlobLen(bytes: []const u8, start_cursor: usize, entry_count: usize) !usize {
    var cursor = start_cursor;
    var total: usize = 0;
    for (0..entry_count) |_| {
        _ = try readU32(bytes, &cursor);
        _ = try readU16(bytes, &cursor);
        _ = try readU16(bytes, &cursor);
        _ = try readI32(bytes, &cursor);
        const feature_len: usize = @intCast(try readU32(bytes, &cursor));
        total = try std.math.add(usize, total, feature_len);
        _ = try readSlice(bytes, &cursor, feature_len);
    }
    return total;
}

fn parseEntries(allocator: Allocator, input: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(allocator, entries.items);
    errdefer entries.deinit(allocator);
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ',');
        try entries.append(allocator, try parseEntryFields(allocator, &fields));
    }
    try appendCompatibilityEntries(allocator, &entries);
    return entries.toOwnedSlice(allocator);
}

fn appendCompatibilityEntries(allocator: Allocator, entries: *std.ArrayList(Entry)) !void {
    // Vibrato's distributed IPADIC system dictionary returns U+2015 as a known
    // punctuation token even though the raw CSV lexicon does not contain it.
    // Add the same one-character entry when building native dictionaries so
    // fraim-lint-rs preserves the public token shape while still avoiding the
    // Vibrato runtime.
    if (hasSurface(entries.items, "―")) return;
    try entries.append(allocator, .{
        .surface = try allocator.dupe(u8, "―"),
        .left_id = 5,
        .right_id = 5,
        .word_cost = 4769,
        .feature = try allocator.dupe(u8, "記号,一般,*,*,*,*,―,―,―"),
    });
}

fn hasSurface(entries: []const Entry, surface: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.surface, surface)) return true;
    }
    return false;
}

fn parseUnkEntries(allocator: Allocator, input: []const u8, char_property: *const CharProperty) ![]UnkEntry {
    var entries: std.ArrayList(UnkEntry) = .empty;
    errdefer freeUnks(allocator, entries.items);
    errdefer entries.deinit(allocator);
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ',');
        const category_name = fields.next() orelse return error.InvalidDictionary;
        const left_id = try std.fmt.parseInt(u16, fields.next() orelse return error.InvalidDictionary, 10);
        const right_id = try std.fmt.parseInt(u16, fields.next() orelse return error.InvalidDictionary, 10);
        const word_cost = try std.fmt.parseInt(i32, fields.next() orelse return error.InvalidDictionary, 10);
        const feature = try collectRestCsv(allocator, &fields);
        errdefer allocator.free(feature);
        try entries.append(allocator, .{
            .category_id = char_property.categoryId(category_name) orelse return error.InvalidDictionary,
            .left_id = left_id,
            .right_id = right_id,
            .word_cost = word_cost,
            .feature = feature,
        });
    }
    return entries.toOwnedSlice(allocator);
}

fn parseEntryFields(allocator: Allocator, fields: *std.mem.SplitIterator(u8, .scalar)) !Entry {
    const surface = fields.next() orelse return error.InvalidDictionary;
    const left_id = try std.fmt.parseInt(u16, fields.next() orelse return error.InvalidDictionary, 10);
    const right_id = try std.fmt.parseInt(u16, fields.next() orelse return error.InvalidDictionary, 10);
    const word_cost = try std.fmt.parseInt(i32, fields.next() orelse return error.InvalidDictionary, 10);
    return .{
        .surface = try allocator.dupe(u8, surface),
        .left_id = left_id,
        .right_id = right_id,
        .word_cost = word_cost,
        .feature = try collectRestCsv(allocator, fields),
    };
}

fn collectRestCsv(allocator: Allocator, fields: *std.mem.SplitIterator(u8, .scalar)) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var first = true;
    while (fields.next()) |field| {
        if (!first) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, field);
        first = false;
    }
    return buf.toOwnedSlice(allocator);
}

fn defaultUnkEntries(allocator: Allocator) ![]UnkEntry {
    const entries = try allocator.alloc(UnkEntry, 1);
    entries[0] = .{
        .category_id = 0,
        .left_id = 0,
        .right_id = 0,
        .word_cost = 10_000,
        .feature = try allocator.dupe(u8, "UNK"),
    };
    return entries;
}

fn findCategoryId(categories: []const CharCategory, name: []const u8) ?usize {
    for (categories, 0..) |category, i| {
        if (std.mem.eql(u8, category.name, name)) return i;
    }
    return null;
}

fn parseCodepointRange(input: []const u8) !struct { start: u32, end: u32 } {
    var parts = std.mem.splitSequence(u8, input, "..");
    const start = try parseHex(parts.next() orelse return error.InvalidDictionary);
    const end = if (parts.next()) |end_text| try parseHex(end_text) + 1 else start + 1;
    if (parts.next() != null or start >= end) return error.InvalidDictionary;
    return .{ .start = start, .end = end };
}

fn parseHex(input: []const u8) !u32 {
    const hex = if (std.mem.startsWith(u8, input, "0x")) input[2..] else input;
    return std.fmt.parseInt(u32, hex, 16);
}

fn parseBool01(input: []const u8) !bool {
    if (std.mem.eql(u8, input, "0")) return false;
    if (std.mem.eql(u8, input, "1")) return true;
    return error.InvalidDictionary;
}

fn freeEntrySlice(allocator: Allocator, entries: []Entry) void {
    freeEntries(allocator, entries);
    allocator.free(entries);
}

fn freeEntries(allocator: Allocator, entries: []Entry) void {
    for (entries) |entry| {
        allocator.free(entry.surface);
        allocator.free(entry.feature);
    }
}

fn freeUnkSlice(allocator: Allocator, entries: []UnkEntry) void {
    freeUnks(allocator, entries);
    allocator.free(entries);
}

fn freeUnks(allocator: Allocator, entries: []UnkEntry) void {
    for (entries) |entry| allocator.free(entry.feature);
}

test "double-array free bitmap search matches a linear scan" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    var round: usize = 0;
    while (round < 200) : (round += 1) {
        const slot_len: usize = 64 * (1 + random.uintLessThan(usize, 64));
        var free: DoubleArrayFreeBits = .{};
        defer free.deinit(allocator);
        try free.grow(allocator, slot_len);
        const used = try allocator.alloc(bool, slot_len);
        defer allocator.free(used);
        const density = random.uintLessThan(u32, 100);
        for (used, 0..) |*u, slot| {
            u.* = random.uintLessThan(u32, 100) < density;
            if (u.*) free.markUsed(slot);
        }

        var edge_buf: [256]TrieEdge = undefined;
        const edge_len = 1 + random.uintLessThan(usize, 12);
        var byte_set = std.StaticBitSet(256).initEmpty();
        while (byte_set.count() < edge_len) byte_set.set(random.int(u8));
        var it = byte_set.iterator(.{});
        var n: usize = 0;
        while (it.next()) |byte| : (n += 1) edge_buf[n] = .{ .byte = @intCast(byte), .child = 0 };
        const node_edges = edge_buf[0..n];

        const start = 1 + random.uintLessThan(usize, slot_len);
        var expected = start;
        while (true) : (expected += 1) {
            var fits = true;
            for (node_edges) |edge| {
                const slot = expected + edge.byte;
                if (slot < slot_len and used[slot]) fits = false;
            }
            if (fits) break;
        }
        try std.testing.expectEqual(expected, free.findBase(node_edges, start));

        var expected_free = start;
        while (expected_free < slot_len and used[expected_free]) expected_free += 1;
        try std.testing.expectEqual(expected_free, @min(free.nextFree(start), slot_len));
    }
}

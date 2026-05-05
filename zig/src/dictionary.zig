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

// Each trie node stores offsets into global edge/term streams. IPADIC stays far
// below 24-bit offsets and 16-bit per-node term counts, so the in-memory node
// can be packed to reduce resident memory while the binary file layout remains
// unchanged and backward-compatible.
pub const TrieNode = packed struct {
    edge_start: u24,
    edge_len: u16,
    word_start: u24,
    word_len: u16,
    count_word_start: u24,
    count_word_len: u16,
};

pub const TrieTerm = struct {
    word_id: u32,
    left_id: u16,
    right_id: u16,
    word_cost: i32,
};

// Count-only tokenization never needs the dictionary word id or feature
// payload. Keeping this term at 8 bytes reduces the hot trie term stream for
// `tokenizeCount` and avoids loading data that cannot affect the best path.
pub const TrieCountTerm = struct {
    left_id: u16,
    right_id: u16,
    word_cost: i32,
};

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
    range_bmp: []u32,
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
                const range = self.ranges[range_index];
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
        if (cp < 0x10000) return self.invoke_bmp[cp] != 0;
        return self.info(ch).category.invoke;
    }
};

fn buildInvokeBmp(allocator: Allocator, categories: []const CharCategory, ranges: []const CharRange) ![]u8 {
    const invoke_bmp = try allocator.alloc(u8, 0x10000);
    @memset(invoke_bmp, if (categories[0].invoke) 1 else 0);
    for (ranges) |range| {
        if (range.start >= 0x10000) continue;
        const end = @min(range.end, 0x10000);
        const invoke: u8 = if (categories[range.category_ids[0]].invoke) 1 else 0;
        @memset(invoke_bmp[@intCast(range.start)..@intCast(end)], invoke);
    }
    return invoke_bmp;
}

const invalid_range_index = std.math.maxInt(u32);

fn buildRangeBmp(allocator: Allocator, ranges: []const CharRange) ![]u32 {
    const range_bmp = try allocator.alloc(u32, 0x10000);
    @memset(range_bmp, invalid_range_index);
    for (ranges, 0..) |range, range_index| {
        if (range.start >= 0x10000) continue;
        const end = @min(range.end, 0x10000);
        @memset(range_bmp[@intCast(range.start)..@intCast(end)], @as(u32, @intCast(range_index)));
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
    trie_nodes: []TrieNode,
    trie_edges: []TrieEdge,
    trie_terms: []TrieTerm,
    trie_count_terms: []TrieCountTerm,
    trie_first: [256]u32,
    trie_bmp: []align(1) const u32,
    trie_pair: []align(1) const u32,
    trie_triple: []align(1) const u32,
    trie_base: []align(1) const u32,
    trie_check: []align(1) const u32,
    trie_child: []align(1) const u32,
    owns_trie_u32_tables: bool,

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

    pub fn fromBinaryFile(allocator: Allocator, path: []const u8) !Dictionary {
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

        for (self.matrix.costs) |cost| try appendI16(allocator, &bytes, cost);

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

        for (self.trie_nodes) |node| {
            try appendU32(allocator, &bytes, node.edge_start);
            try appendU16(allocator, &bytes, node.edge_len);
            try appendU32(allocator, &bytes, node.word_start);
            try appendU32(allocator, &bytes, node.word_len);
            try appendU32(allocator, &bytes, node.count_word_start);
            try appendU32(allocator, &bytes, node.count_word_len);
        }
        for (self.trie_edges) |edge| {
            try appendU8(allocator, &bytes, edge.byte);
            try appendU32(allocator, &bytes, edge.child);
        }
        for (self.trie_terms) |term| {
            try appendU32(allocator, &bytes, term.word_id);
            try appendU16(allocator, &bytes, term.left_id);
            try appendU16(allocator, &bytes, term.right_id);
            try appendI32(allocator, &bytes, term.word_cost);
        }
        for (self.trie_count_terms) |term| {
            try appendU16(allocator, &bytes, term.left_id);
            try appendU16(allocator, &bytes, term.right_id);
            try appendI32(allocator, &bytes, term.word_cost);
        }
        try appendU32Slice(allocator, &bytes, self.trie_pair);
        try appendU32Slice(allocator, &bytes, self.trie_bmp);
        try appendU32Slice(allocator, &bytes, self.trie_triple);
        try appendU32Slice(allocator, &bytes, self.trie_base);
        try appendU32Slice(allocator, &bytes, self.trie_check);
        try appendU32Slice(allocator, &bytes, self.trie_child);
        return bytes.toOwnedSlice(allocator);
    }

    pub fn fromBinaryBytes(allocator: Allocator, bytes: []const u8) !Dictionary {
        return fromBinaryBytesInternal(allocator, bytes, true);
    }

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
        for (0..@intCast(entry_count)) |entry_index| {
            const surface_len: usize = @intCast(try readU32(bytes, &cursor));
            const left_id = try readU16(bytes, &cursor);
            const right_id = try readU16(bytes, &cursor);
            const word_cost = try readI32(bytes, &cursor);
            const feature_len: usize = @intCast(try readU32(bytes, &cursor));
            const surface = try readSlice(bytes, &cursor, surface_len);
            const feature = try readSlice(bytes, &cursor, feature_len);
            if (compact_entry_features) {
                const feature_offset = if (copy_feature_blob) copied: {
                    const feature_start = entry_blob_cursor;
                    @memcpy(entry_blob_owned[feature_start .. feature_start + feature_len], feature);
                    entry_blob_cursor += feature_len;
                    break :copied feature_start;
                } else @intFromPtr(feature.ptr) - @intFromPtr(entry_blob.ptr);
                if (feature_offset > std.math.maxInt(u32) or feature_len > std.math.maxInt(u32)) return error.InvalidDictionary;
                entry_features[entry_index] = .{ .offset = @intCast(feature_offset), .len = @intCast(feature_len) };
                continue;
            }
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
        errdefer {
            for (ranges) |range| allocator.free(range.category_ids);
            allocator.free(ranges);
        }
        for (ranges) |*range| {
            const start = try readU32(bytes, &cursor);
            const end = try readU32(bytes, &cursor);
            const id_count: usize = @intCast(try readU32(bytes, &cursor));
            const ids = try allocator.alloc(usize, id_count);
            for (ids) |*id| id.* = try readU32(bytes, &cursor);
            range.* = .{ .start = start, .end = end, .category_ids = ids };
        }

        const matrix_len = @as(usize, @intCast(right_size)) * @as(usize, @intCast(left_size));
        const costs = try readI16Slice(allocator, bytes, &cursor, matrix_len, borrow_binary_tables);
        errdefer if (!borrow_binary_tables) allocator.free(costs);
        const matrix: ConnectionMatrix = .{ .left_size = @intCast(left_size), .right_size = @intCast(right_size), .costs = costs };

        const invoke_bmp = try buildInvokeBmp(allocator, categories, ranges);
        errdefer allocator.free(invoke_bmp);
        const range_bmp = try buildRangeBmp(allocator, ranges);
        errdefer allocator.free(range_bmp);
        var char_property: CharProperty = .{
            .allocator = allocator,
            .categories = categories,
            .ranges = ranges,
            .invoke_bmp = invoke_bmp,
            .range_bmp = range_bmp,
            .has_invoke = has_invoke,
        };
        errdefer char_property.deinit();
        const entry_index = if (entries.len <= 32) try buildEntryIndex(allocator, entries) else EntryIndex.empty();
        errdefer entry_index.deinit(allocator);
        const unk_index = try buildUnkIndex(allocator, @intCast(category_count), unk_entries, &matrix);
        errdefer unk_index.deinit(allocator);

        var trie_nodes: []TrieNode = &.{};
        var trie_edges: []TrieEdge = &.{};
        var trie_terms: []TrieTerm = &.{};
        var trie_count_terms: []TrieCountTerm = &.{};
        var trie_pair: []align(1) const u32 = &.{};
        var trie_bmp: []align(1) const u32 = &.{};
        var trie_triple: []align(1) const u32 = &.{};
        var trie_base: []align(1) const u32 = &.{};
        var trie_check: []align(1) const u32 = &.{};
        var trie_child: []align(1) const u32 = &.{};
        var owns_trie_u32_tables = true;

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

            trie_nodes = try readTrieNodes(allocator, bytes, &cursor, @intCast(trie_node_count));
            errdefer allocator.free(trie_nodes);
            trie_edges = try readTrieEdges(allocator, bytes, &cursor, @intCast(trie_edge_count));
            errdefer allocator.free(trie_edges);
            trie_terms = try readTrieTerms(allocator, bytes, &cursor, @intCast(trie_term_count));
            errdefer allocator.free(trie_terms);
            trie_count_terms = try readTrieCountTerms(allocator, bytes, &cursor, @intCast(trie_count_term_count));
            errdefer allocator.free(trie_count_terms);
            owns_trie_u32_tables = !borrow_binary_tables;
            trie_pair = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_pair_count), borrow_binary_tables);
            errdefer if (owns_trie_u32_tables and trie_pair.len != 0) freeU32Slice(allocator, trie_pair);
            trie_bmp = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_bmp_count), borrow_binary_tables);
            errdefer if (owns_trie_u32_tables and trie_bmp.len != 0) freeU32Slice(allocator, trie_bmp);
            trie_triple = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_triple_count), borrow_binary_tables);
            errdefer if (owns_trie_u32_tables and trie_triple.len != 0) freeU32Slice(allocator, trie_triple);
            trie_base = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_base_count), borrow_binary_tables);
            errdefer if (owns_trie_u32_tables and trie_base.len != 0) freeU32Slice(allocator, trie_base);
            trie_check = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_check_count), borrow_binary_tables);
            errdefer if (owns_trie_u32_tables and trie_check.len != 0) freeU32Slice(allocator, trie_check);
            trie_child = try readU32Slice(allocator, bytes, &cursor, @intCast(trie_child_count), borrow_binary_tables);
            errdefer if (owns_trie_u32_tables and trie_child.len != 0) freeU32Slice(allocator, trie_child);
        } else {
            // Backward compatibility for DLRDIC01 files. New dictionaries write
            // DLRDIC02 and skip this rebuild path entirely.
            const trie = try buildTrie(allocator, entries, &matrix);
            trie_nodes = trie.nodes;
            trie_edges = trie.edges;
            trie_terms = trie.terms;
            trie_count_terms = trie.count_terms;
            errdefer freeTrie(allocator, trie_nodes, trie_edges, trie_terms, trie_count_terms);
            trie_pair = if (entries.len <= 32) emptyU32Slice() else try buildTriePair(allocator, trie_nodes, trie_edges);
            errdefer if (trie_pair.len != 0) freeU32Slice(allocator, trie_pair);
            trie_bmp = if (entries.len <= 32) emptyU32Slice() else try buildTrieBmp(allocator, trie_nodes, trie_edges);
            errdefer if (trie_bmp.len != 0) freeU32Slice(allocator, trie_bmp);
            trie_triple = try buildTrieTriple(allocator, trie_nodes, trie_edges);
            errdefer if (trie_triple.len != 0) freeU32Slice(allocator, trie_triple);
            const double_array = try buildDoubleArray(allocator, trie_nodes, trie_edges);
            trie_base = double_array.base;
            trie_check = double_array.check;
            trie_child = double_array.child;
            errdefer freeDoubleArray(allocator, double_array);
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
        freeTrie(self.allocator, self.trie_nodes, self.trie_edges, self.trie_terms, self.trie_count_terms);
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

        self.allocator.free(self.trie_terms);
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

const BuildTrieNode = struct {
    edges: std.ArrayList(TrieEdge) = .empty,
    word_ids: std.ArrayList(u32) = .empty,
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
    var build_nodes: std.ArrayList(BuildTrieNode) = .empty;
    defer {
        for (build_nodes.items) |*node| {
            node.edges.deinit(allocator);
            node.word_ids.deinit(allocator);
        }
        build_nodes.deinit(allocator);
    }

    try build_nodes.append(allocator, .{});
    for (entries, 0..) |entry, word_id| {
        var node_index: usize = 0;
        for (entry.surface) |byte| {
            if (findEdgeSlice(build_nodes.items[node_index].edges.items, byte)) |child| {
                node_index = child;
            } else {
                const child = build_nodes.items.len;
                try build_nodes.append(allocator, .{});
                try build_nodes.items[node_index].edges.append(allocator, .{ .byte = byte, .child = @intCast(child) });
                node_index = child;
            }
        }
        try build_nodes.items[node_index].word_ids.append(allocator, @intCast(word_id));
    }

    var edge_count: usize = 0;
    var word_id_count: usize = 0;
    for (build_nodes.items) |*node| {
        std.mem.sort(TrieEdge, node.edges.items, {}, trieEdgeLessThan);
        edge_count += node.edges.items.len;
        word_id_count += node.word_ids.items.len;
    }

    const nodes = try allocator.alloc(TrieNode, build_nodes.items.len);
    errdefer allocator.free(nodes);
    const edges = try allocator.alloc(TrieEdge, edge_count);
    errdefer allocator.free(edges);
    const terms = try allocator.alloc(TrieTerm, word_id_count);
    errdefer allocator.free(terms);
    var count_terms: std.ArrayList(TrieCountTerm) = .empty;
    errdefer count_terms.deinit(allocator);

    var edge_offset: usize = 0;
    var word_offset: usize = 0;
    for (build_nodes.items, 0..) |node, i| {
        @memcpy(edges[edge_offset .. edge_offset + node.edges.items.len], node.edges.items);
        const count_start = count_terms.items.len;
        for (node.word_ids.items, 0..) |word_id, j| {
            const entry = entries[word_id];
            const term: TrieTerm = .{
                .word_id = word_id,
                .left_id = entry.left_id,
                .right_id = entry.right_id,
                .word_cost = entry.word_cost,
            };
            terms[word_offset + j] = term;
            try appendCountTerm(allocator, &count_terms, term, count_start, matrix);
        }
        nodes[i] = .{
            .edge_start = try narrowTrieOffset(edge_offset),
            .edge_len = @intCast(node.edges.items.len),
            .word_start = try narrowTrieOffset(word_offset),
            .word_len = try narrowTrieTermLen(node.word_ids.items.len),
            .count_word_start = try narrowTrieOffset(count_start),
            .count_word_len = try narrowTrieTermLen(count_terms.items.len - count_start),
        };
        edge_offset += node.edges.items.len;
        word_offset += node.word_ids.items.len;
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

fn findEdgeSlice(edges: []const TrieEdge, byte: u8) ?usize {
    for (edges) |edge| {
        if (edge.byte == byte) return @intCast(edge.child);
    }
    return null;
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

    var used: std.ArrayList(u8) = .empty;
    defer used.deinit(allocator);
    var check: std.ArrayList(u32) = .empty;
    errdefer check.deinit(allocator);
    var child: std.ArrayList(u32) = .empty;
    errdefer child.deinit(allocator);

    try ensureDoubleArrayCapacity(allocator, &used, &check, &child, 512);
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
        var candidate = if (next_free > first_byte) next_free - first_byte else 1;

        while (true) : (candidate += 1) {
            const first_slot = candidate + first_byte;
            if (first_slot < used.items.len and used.items[first_slot] != 0) continue;
            if (doubleArrayBaseFits(used.items, node_edges, candidate)) break;
        }

        var max_slot: usize = 0;
        for (node_edges) |edge| max_slot = @max(max_slot, candidate + edge.byte);
        try ensureDoubleArrayCapacity(allocator, &used, &check, &child, max_slot + 1);

        base[node_index] = @intCast(candidate);
        for (node_edges) |edge| {
            const slot = candidate + edge.byte;
            used.items[slot] = 1;
            check.items[slot] = @intCast(node_index);
            child.items[slot] = edge.child;
        }
        while (next_free < used.items.len and used.items[next_free] != 0) next_free += 1;
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

fn narrowTrieTermLen(len: usize) !u16 {
    if (len > std.math.maxInt(u16)) return error.InvalidDictionary;
    return @intCast(len);
}

fn narrowTrieOffset(offset: usize) !u24 {
    if (offset > std.math.maxInt(u24)) return error.InvalidDictionary;
    return @intCast(offset);
}

fn doubleArrayBaseFits(used: []const u8, node_edges: []const TrieEdge, candidate: usize) bool {
    for (node_edges) |edge| {
        const slot = candidate + edge.byte;
        if (slot < used.len and used[slot] != 0) return false;
    }
    return true;
}

fn ensureDoubleArrayCapacity(
    allocator: Allocator,
    used: *std.ArrayList(u8),
    check: *std.ArrayList(u32),
    child: *std.ArrayList(u32),
    required: usize,
) !void {
    if (used.items.len >= required) return;
    var new_len = @max(used.items.len, @as(usize, 512));
    while (new_len < required) new_len *= 2;

    const old_len = used.items.len;
    try used.resize(allocator, new_len);
    try check.resize(allocator, new_len);
    try child.resize(allocator, new_len);
    @memset(used.items[old_len..], 0);
    @memset(check.items[old_len..], invalid_trie_node);
    @memset(child.items[old_len..], invalid_trie_node);
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

pub inline fn trieTerms(nodes: []const TrieNode, trie_terms: []const TrieTerm, node_index: usize) []const TrieTerm {
    const node = nodes[node_index];
    const start: usize = @intCast(node.word_start);
    const len: usize = @intCast(node.word_len);
    return trie_terms[start .. start + len];
}

pub inline fn trieCountTerms(nodes: []const TrieNode, trie_terms: []const TrieCountTerm, node_index: usize) []const TrieCountTerm {
    const node = nodes[node_index];
    const start: usize = @intCast(node.count_word_start);
    const len: usize = @intCast(node.count_word_len);
    return trie_terms[start .. start + len];
}

fn trieEdgeLessThan(_: void, lhs: TrieEdge, rhs: TrieEdge) bool {
    return lhs.byte < rhs.byte;
}

fn freeTrie(allocator: Allocator, nodes: []TrieNode, edges: []TrieEdge, terms_slice: []TrieTerm, count_terms_slice: []TrieCountTerm) void {
    allocator.free(nodes);
    allocator.free(edges);
    allocator.free(terms_slice);
    allocator.free(count_terms_slice);
}

fn freeU32Slice(allocator: Allocator, values: []align(1) const u32) void {
    const aligned: []const u32 = @alignCast(values);
    allocator.free(@constCast(aligned));
}

fn freeI16Slice(allocator: Allocator, values: []align(1) const i16) void {
    const aligned: []const i16 = @alignCast(values);
    allocator.free(@constCast(aligned));
}

pub fn readFileAlloc(allocator: Allocator, path: []const u8) ![]u8 {
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    return std.Io.Dir.cwd().readFileAlloc(io_instance.io(), path, allocator, .limited(256 * 1024 * 1024));
}

fn appendU8(allocator: Allocator, bytes: *std.ArrayList(u8), value: u8) !void {
    try bytes.append(allocator, value);
}

fn appendU16(allocator: Allocator, bytes: *std.ArrayList(u8), value: u16) !void {
    try appendU8(allocator, bytes, @intCast(value & 0xff));
    try appendU8(allocator, bytes, @intCast(value >> 8));
}

fn appendI16(allocator: Allocator, bytes: *std.ArrayList(u8), value: i16) !void {
    try appendU16(allocator, bytes, @bitCast(value));
}

fn appendU32(allocator: Allocator, bytes: *std.ArrayList(u8), value: u32) !void {
    try appendU8(allocator, bytes, @intCast(value & 0xff));
    try appendU8(allocator, bytes, @intCast((value >> 8) & 0xff));
    try appendU8(allocator, bytes, @intCast((value >> 16) & 0xff));
    try appendU8(allocator, bytes, @intCast(value >> 24));
}

fn appendI32(allocator: Allocator, bytes: *std.ArrayList(u8), value: i32) !void {
    try appendU32(allocator, bytes, @bitCast(value));
}

fn appendU32Slice(allocator: Allocator, bytes: *std.ArrayList(u8), values: []align(1) const u32) !void {
    for (values) |value| try appendU32(allocator, bytes, value);
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
    if (borrow) {
        const raw = try readSlice(bytes, cursor, try std.math.mul(usize, count, 2));
        return std.mem.bytesAsSlice(i16, raw);
    }
    const values = try allocator.alloc(i16, count);
    errdefer allocator.free(values);
    for (values) |*value| value.* = try readI16(bytes, cursor);
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

fn readTrieNodes(allocator: Allocator, bytes: []const u8, cursor: *usize, count: usize) ![]TrieNode {
    const nodes = try allocator.alloc(TrieNode, count);
    errdefer allocator.free(nodes);
    for (nodes) |*node| {
        node.* = .{
            .edge_start = try narrowTrieOffset(try readU32(bytes, cursor)),
            .edge_len = try readU16(bytes, cursor),
            .word_start = try narrowTrieOffset(try readU32(bytes, cursor)),
            .word_len = try narrowTrieTermLen(try readU32(bytes, cursor)),
            .count_word_start = try narrowTrieOffset(try readU32(bytes, cursor)),
            .count_word_len = try narrowTrieTermLen(try readU32(bytes, cursor)),
        };
    }
    return nodes;
}

fn readTrieEdges(allocator: Allocator, bytes: []const u8, cursor: *usize, count: usize) ![]TrieEdge {
    const edges = try allocator.alloc(TrieEdge, count);
    errdefer allocator.free(edges);
    for (edges) |*edge| {
        edge.* = .{
            .byte = try readU8(bytes, cursor),
            .child = try readU32(bytes, cursor),
        };
    }
    return edges;
}

fn readTrieTerms(allocator: Allocator, bytes: []const u8, cursor: *usize, count: usize) ![]TrieTerm {
    const terms = try allocator.alloc(TrieTerm, count);
    errdefer allocator.free(terms);
    for (terms) |*term| {
        term.* = .{
            .word_id = try readU32(bytes, cursor),
            .left_id = try readU16(bytes, cursor),
            .right_id = try readU16(bytes, cursor),
            .word_cost = try readI32(bytes, cursor),
        };
    }
    return terms;
}

fn readTrieCountTerms(allocator: Allocator, bytes: []const u8, cursor: *usize, count: usize) ![]TrieCountTerm {
    const terms = try allocator.alloc(TrieCountTerm, count);
    errdefer allocator.free(terms);
    for (terms) |*term| {
        term.* = .{
            .left_id = try readU16(bytes, cursor),
            .right_id = try readU16(bytes, cursor),
            .word_cost = try readI32(bytes, cursor),
        };
    }
    return terms;
}

fn readU32Slice(allocator: Allocator, bytes: []const u8, cursor: *usize, count: usize, borrow: bool) ![]align(1) const u32 {
    if (count == 0) return emptyU32Slice();
    if (borrow) {
        const raw = try readSlice(bytes, cursor, try std.math.mul(usize, count, 4));
        return std.mem.bytesAsSlice(u32, raw);
    }
    const values = try allocator.alloc(u32, count);
    errdefer allocator.free(values);
    for (values) |*value| value.* = try readU32(bytes, cursor);
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
        const surface_len: usize = @intCast(try readU32(bytes, &cursor));
        _ = try readU16(bytes, &cursor);
        _ = try readU16(bytes, &cursor);
        _ = try readI32(bytes, &cursor);
        const feature_len: usize = @intCast(try readU32(bytes, &cursor));
        total = try std.math.add(usize, total, feature_len);
        _ = try readSlice(bytes, &cursor, surface_len);
        _ = try readSlice(bytes, &cursor, feature_len);
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

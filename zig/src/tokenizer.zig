const std = @import("std");
const dict_mod = @import("dictionary.zig");

const Allocator = std.mem.Allocator;

pub const unknown_word_base: u32 = 1 << 31;
pub const unknown_word_id: u32 = std.math.maxInt(u32);
const invalid_node: usize = std.math.maxInt(usize);

pub const Token = struct {
    start: usize,
    end: usize,
    word_id: u32,
    feature: [:0]const u8,
    total_cost: i32,

    pub fn isUnknown(self: Token) bool {
        return self.word_id >= unknown_word_base;
    }
};

const Node = struct {
    word_id: u32,
    start: usize,
    end: usize,
    right_id: u16,
    min_cost: i32,
    prev_node: ?usize,
    next_end: usize,

    fn bos() Node {
        return .{
            .word_id = unknown_word_id,
            .start = 0,
            .end = 0,
            .right_id = 0,
            .min_cost = 0,
            .prev_node = null,
            .next_end = invalid_node,
        };
    }
};

const CountNode = struct {
    right_id: u16,
    min_cost: i32,
    token_count: usize,
    next_end: usize,

    fn bos() CountNode {
        return .{
            .right_id = 0,
            .min_cost = 0,
            .token_count = 0,
            .next_end = invalid_node,
        };
    }
};

const Candidate = struct {
    word_id: u32,
    left_id: u16,
    right_id: u16,
    word_cost: i32,
};

const CountCandidate = struct {
    left_id: u16,
    right_id: u16,
    word_cost: i32,
};

pub const Tokenizer = struct {
    allocator: Allocator,
    dictionary: dict_mod.Dictionary,
    max_grouping_len: ?usize = null,

    pub fn initMinimalFile(allocator: Allocator, dict_path: []const u8) !Tokenizer {
        return .{ .allocator = allocator, .dictionary = try dict_mod.Dictionary.fromMinimalFile(allocator, dict_path) };
    }

    pub fn initRawFiles(allocator: Allocator, lex_path: []const u8, matrix_path: []const u8, char_path: []const u8, unk_path: []const u8) !Tokenizer {
        return .{
            .allocator = allocator,
            .dictionary = try dict_mod.Dictionary.fromRawFiles(allocator, lex_path, matrix_path, char_path, unk_path),
        };
    }

    pub fn initBinaryFile(allocator: Allocator, dict_path: []const u8) !Tokenizer {
        return .{ .allocator = allocator, .dictionary = try dict_mod.Dictionary.fromBinaryFile(allocator, dict_path) };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.dictionary.deinit();
    }

    pub fn createWorker(self: *Tokenizer, allocator: Allocator) Worker {
        return Worker.init(allocator, &self.dictionary, self.max_grouping_len);
    }
};

pub const Worker = struct {
    allocator: Allocator,
    dictionary: *const dict_mod.Dictionary,
    max_grouping_len: ?usize,
    nodes: std.ArrayList(Node),
    end_heads: std.ArrayList(usize),
    count_nodes: std.ArrayList(CountNode),
    count_end_heads: std.ArrayList(usize),
    tokens: std.ArrayList(Token),

    pub fn init(allocator: Allocator, dictionary: *const dict_mod.Dictionary, max_grouping_len: ?usize) Worker {
        return .{
            .allocator = allocator,
            .dictionary = dictionary,
            .max_grouping_len = max_grouping_len,
            .nodes = .empty,
            .end_heads = .empty,
            .count_nodes = .empty,
            .count_end_heads = .empty,
            .tokens = .empty,
        };
    }

    pub fn deinit(self: *Worker) void {
        self.end_heads.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.count_end_heads.deinit(self.allocator);
        self.count_nodes.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
    }

    pub fn tokenize(self: *Worker, input: []const u8) ![]const Token {
        const best = try self.buildBestPath(input);
        try self.backtrace(input, best);
        return self.tokens.items;
    }

    pub fn tokenizeCount(self: *Worker, input: []const u8) !usize {
        if (input.len == 0) {
            try self.resetCount(0);
            return 0;
        }
        const best = try self.buildBestCountPath(input);
        return self.count_nodes.items[best].token_count;
    }

    fn buildBestPath(self: *Worker, input: []const u8) !usize {
        try self.reset(input.len);
        if (input.len == 0) return error.NoPath;

        try self.nodes.append(self.allocator, Node.bos());
        self.end_heads.items[0] = 0;

        var begin: usize = 0;
        while (begin < input.len) : (begin = nextBoundary(input, begin) orelse input.len) {
            if (self.end_heads.items[begin] == invalid_node) continue;

            var emitted = false;
            if (self.dictionary.user_entries.len != 0) {
                try self.appendEntries(input, begin, self.dictionary.user_entries, 1 << 30, &emitted);
            }
            if (self.dictionary.entries.len <= 32) {
                try self.appendIndexedEntries(input, begin, &emitted);
            } else {
                try self.appendTrieEntries(input, begin, &emitted);
            }
            try self.appendUnknown(input, begin, emitted);
        }

        const best = try self.bestEndNode(input.len);
        return best;
    }

    fn buildBestCountPath(self: *Worker, input: []const u8) !usize {
        try self.resetCount(input.len);
        if (input.len == 0) return error.NoPath;

        try self.count_nodes.append(self.allocator, CountNode.bos());
        self.count_end_heads.items[0] = 0;

        var begin: usize = 0;
        while (begin < input.len) : (begin = nextBoundary(input, begin) orelse input.len) {
            if (self.count_end_heads.items[begin] == invalid_node) continue;

            var emitted = false;
            if (self.dictionary.user_entries.len != 0) {
                try self.appendEntriesCount(input, begin, self.dictionary.user_entries, &emitted);
            }
            if (self.dictionary.entries.len <= 32) {
                try self.appendIndexedEntriesCount(input, begin, &emitted);
            } else {
                try self.appendTrieEntriesCount(input, begin, &emitted);
            }
            try self.appendUnknownCount(input, begin, emitted);
        }

        return self.bestCountEndNode(input.len);
    }

    fn appendEntries(self: *Worker, input: []const u8, begin: usize, entries: []const dict_mod.Entry, word_base: u32, emitted: *bool) !void {
        for (entries, 0..) |entry, word_id| {
            if (std.mem.startsWith(u8, input[begin..], entry.surface)) {
                const end = begin + entry.surface.len;
                try self.appendBestNode(begin, end, .{
                    .word_id = word_base + @as(u32, @intCast(word_id)),
                    .left_id = entry.left_id,
                    .right_id = entry.right_id,
                    .word_cost = entry.word_cost,
                });
                emitted.* = true;
            }
        }
    }

    fn appendTrieEntries(self: *Worker, input: []const u8, begin: usize, emitted: *bool) !void {
        const first_node = self.dictionary.trie_first[input[begin]];
        if (first_node == dict_mod.invalid_trie_node) return;
        var node_index: usize = @intCast(first_node);
        for (dict_mod.trieTerms(self.dictionary.trie_nodes, self.dictionary.trie_terms, node_index)) |term| {
            try self.appendBestNode(begin, begin + 1, .{
                .word_id = term.word_id,
                .left_id = term.left_id,
                .right_id = term.right_id,
                .word_cost = term.word_cost,
            });
            emitted.* = true;
        }
        var pos = begin + 1;
        if (pos < input.len) {
            const pair_index = (@as(usize, input[begin]) << 8) | @as(usize, input[begin + 1]);
            const pair_node = self.dictionary.trie_pair[pair_index];
            if (pair_node == dict_mod.invalid_trie_node) return;
            node_index = @intCast(pair_node);
            for (dict_mod.trieTerms(self.dictionary.trie_nodes, self.dictionary.trie_terms, node_index)) |term| {
                try self.appendBestNode(begin, begin + 2, .{
                    .word_id = term.word_id,
                    .left_id = term.left_id,
                    .right_id = term.right_id,
                    .word_cost = term.word_cost,
                });
                emitted.* = true;
            }
            pos = begin + 2;
        }
        if (self.dictionary.trie_triple.len != 0 and pos < input.len) {
            const triple_index = (@as(usize, input[begin]) << 16) | (@as(usize, input[begin + 1]) << 8) | @as(usize, input[begin + 2]);
            const triple_node = self.dictionary.trie_triple[triple_index];
            if (triple_node == dict_mod.invalid_trie_node) return;
            node_index = @intCast(triple_node);
            for (dict_mod.trieTerms(self.dictionary.trie_nodes, self.dictionary.trie_terms, node_index)) |term| {
                try self.appendBestNode(begin, begin + 3, .{
                    .word_id = term.word_id,
                    .left_id = term.left_id,
                    .right_id = term.right_id,
                    .word_cost = term.word_cost,
                });
                emitted.* = true;
            }
            pos = begin + 3;
        }
        while (pos < input.len) : (pos += 1) {
            node_index = self.findTrieEdge(node_index, input[pos]) orelse break;
            for (dict_mod.trieTerms(self.dictionary.trie_nodes, self.dictionary.trie_terms, node_index)) |term| {
                try self.appendBestNode(begin, pos + 1, .{
                    .word_id = term.word_id,
                    .left_id = term.left_id,
                    .right_id = term.right_id,
                    .word_cost = term.word_cost,
                });
                emitted.* = true;
            }
        }
    }

    inline fn findTrieEdge(self: *Worker, node_index: usize, byte: u8) ?usize {
        if (self.dictionary.trie_base.len != 0 and self.dictionary.trie_nodes[node_index].edge_len >= 4) {
            return dict_mod.findDoubleArray(
                self.dictionary.trie_base,
                self.dictionary.trie_check,
                self.dictionary.trie_child,
                node_index,
                byte,
            );
        }
        return dict_mod.findEdge(self.dictionary.trie_nodes, self.dictionary.trie_edges, node_index, byte);
    }

    fn appendIndexedEntries(self: *Worker, input: []const u8, begin: usize, emitted: *bool) !void {
        for (self.dictionary.entry_index.buckets[input[begin]]) |word_id| {
            const entry = self.dictionary.entries[word_id];
            if (surfaceMatchesIndexed(input, begin, entry.surface)) {
                try self.appendBestNode(begin, begin + entry.surface.len, .{
                    .word_id = word_id,
                    .left_id = entry.left_id,
                    .right_id = entry.right_id,
                    .word_cost = entry.word_cost,
                });
                emitted.* = true;
            }
        }
    }

    fn appendEntriesCount(self: *Worker, input: []const u8, begin: usize, entries: []const dict_mod.Entry, emitted: *bool) !void {
        for (entries) |entry| {
            if (std.mem.startsWith(u8, input[begin..], entry.surface)) {
                try self.appendBestCountNode(begin, begin + entry.surface.len, .{
                    .left_id = entry.left_id,
                    .right_id = entry.right_id,
                    .word_cost = entry.word_cost,
                });
                emitted.* = true;
            }
        }
    }

    fn appendTrieEntriesCount(self: *Worker, input: []const u8, begin: usize, emitted: *bool) !void {
        const first_node = self.dictionary.trie_first[input[begin]];
        if (first_node == dict_mod.invalid_trie_node) return;
        var node_index: usize = @intCast(first_node);
        for (dict_mod.trieCountTerms(self.dictionary.trie_nodes, self.dictionary.trie_count_terms, node_index)) |term| {
            try self.appendBestCountNode(begin, begin + 1, .{
                .left_id = term.left_id,
                .right_id = term.right_id,
                .word_cost = term.word_cost,
            });
            emitted.* = true;
        }
        var pos = begin + 1;
        if (pos < input.len) {
            const pair_index = (@as(usize, input[begin]) << 8) | @as(usize, input[begin + 1]);
            const pair_node = self.dictionary.trie_pair[pair_index];
            if (pair_node == dict_mod.invalid_trie_node) return;
            node_index = @intCast(pair_node);
            for (dict_mod.trieCountTerms(self.dictionary.trie_nodes, self.dictionary.trie_count_terms, node_index)) |term| {
                try self.appendBestCountNode(begin, begin + 2, .{
                    .left_id = term.left_id,
                    .right_id = term.right_id,
                    .word_cost = term.word_cost,
                });
                emitted.* = true;
            }
            pos = begin + 2;
        }
        if (self.dictionary.trie_triple.len != 0 and pos < input.len) {
            const triple_index = (@as(usize, input[begin]) << 16) | (@as(usize, input[begin + 1]) << 8) | @as(usize, input[begin + 2]);
            const triple_node = self.dictionary.trie_triple[triple_index];
            if (triple_node == dict_mod.invalid_trie_node) return;
            node_index = @intCast(triple_node);
            for (dict_mod.trieCountTerms(self.dictionary.trie_nodes, self.dictionary.trie_count_terms, node_index)) |term| {
                try self.appendBestCountNode(begin, begin + 3, .{
                    .left_id = term.left_id,
                    .right_id = term.right_id,
                    .word_cost = term.word_cost,
                });
                emitted.* = true;
            }
            pos = begin + 3;
        }
        while (pos < input.len) : (pos += 1) {
            node_index = self.findTrieEdge(node_index, input[pos]) orelse break;
            for (dict_mod.trieCountTerms(self.dictionary.trie_nodes, self.dictionary.trie_count_terms, node_index)) |term| {
                try self.appendBestCountNode(begin, pos + 1, .{
                    .left_id = term.left_id,
                    .right_id = term.right_id,
                    .word_cost = term.word_cost,
                });
                emitted.* = true;
            }
        }
    }

    fn appendIndexedEntriesCount(self: *Worker, input: []const u8, begin: usize, emitted: *bool) !void {
        for (self.dictionary.entry_index.buckets[input[begin]]) |word_id| {
            const entry = self.dictionary.entries[word_id];
            if (surfaceMatchesIndexed(input, begin, entry.surface)) {
                try self.appendBestCountNode(begin, begin + entry.surface.len, .{
                    .left_id = entry.left_id,
                    .right_id = entry.right_id,
                    .word_cost = entry.word_cost,
                });
                emitted.* = true;
            }
        }
    }

    fn appendUnknown(self: *Worker, input: []const u8, begin: usize, has_matched: bool) !void {
        if (has_matched and !self.dictionary.char_property.has_invoke) return;

        const ch = nextCodepoint(input, begin) orelse return error.InvalidDictionary;
        if (has_matched and !self.dictionary.char_property.mayInvoke(ch)) return;
        const info = self.dictionary.char_property.info(ch);

        var emitted = false;
        const group_span = groupSpan(input, begin, &self.dictionary.char_property, info);
        const end_group = group_span.end;
        const group_len = if (info.category.group or info.category.length != 0) group_span.count else 0;
        for (self.dictionary.unk_index.buckets[info.base_id]) |unk| {
            var grouped = false;
            if (info.category.group) {
                const can_group = if (self.max_grouping_len) |max_len| blk: {
                    break :blk group_len -| 1 <= max_len;
                } else true;
                if (can_group) {
                    try self.appendBestNode(begin, end_group, .{
                        .word_id = unknown_word_base + unk.unk_id,
                        .left_id = unk.left_id,
                        .right_id = unk.right_id,
                        .word_cost = unk.word_cost,
                    });
                    emitted = true;
                    grouped = true;
                }
            }
            var len: usize = 1;
            while (len <= @min(info.category.length, group_len)) : (len += 1) {
                if (grouped and len == group_len) continue;
                try self.appendBestNode(begin, try nthBoundary(input, begin, len), .{
                    .word_id = unknown_word_base + unk.unk_id,
                    .left_id = unk.left_id,
                    .right_id = unk.right_id,
                    .word_cost = unk.word_cost,
                });
                emitted = true;
            }
        }

        if (!has_matched and !emitted) {
            const end = nextBoundary(input, begin) orelse return error.InvalidDictionary;
            const fallback = self.dictionary.unk_index.fallback_terms[info.base_id];
            try self.appendBestNode(begin, end, .{
                .word_id = unknown_word_base + fallback.unk_id,
                .left_id = fallback.left_id,
                .right_id = fallback.right_id,
                .word_cost = fallback.word_cost,
            });
        }
    }

    fn appendUnknownCount(self: *Worker, input: []const u8, begin: usize, has_matched: bool) !void {
        if (has_matched and !self.dictionary.char_property.has_invoke) return;

        const ch = nextCodepoint(input, begin) orelse return error.InvalidDictionary;
        if (has_matched and !self.dictionary.char_property.mayInvoke(ch)) return;
        const info = self.dictionary.char_property.info(ch);

        var emitted = false;
        const group_span = groupSpan(input, begin, &self.dictionary.char_property, info);
        const end_group = group_span.end;
        const group_len = if (info.category.group or info.category.length != 0) group_span.count else 0;
        for (self.dictionary.unk_index.buckets[info.base_id]) |unk| {
            var grouped = false;
            if (info.category.group) {
                const can_group = if (self.max_grouping_len) |max_len| blk: {
                    break :blk group_len -| 1 <= max_len;
                } else true;
                if (can_group) {
                    try self.appendBestCountNode(begin, end_group, .{
                        .left_id = unk.left_id,
                        .right_id = unk.right_id,
                        .word_cost = unk.word_cost,
                    });
                    emitted = true;
                    grouped = true;
                }
            }
            var len: usize = 1;
            while (len <= @min(info.category.length, group_len)) : (len += 1) {
                if (grouped and len == group_len) continue;
                try self.appendBestCountNode(begin, try nthBoundary(input, begin, len), .{
                    .left_id = unk.left_id,
                    .right_id = unk.right_id,
                    .word_cost = unk.word_cost,
                });
                emitted = true;
            }
        }

        if (!has_matched and !emitted) {
            const end = nextBoundary(input, begin) orelse return error.InvalidDictionary;
            const fallback = self.dictionary.unk_index.fallback_terms[info.base_id];
            try self.appendBestCountNode(begin, end, .{
                .left_id = fallback.left_id,
                .right_id = fallback.right_id,
                .word_cost = fallback.word_cost,
            });
        }
    }

    fn reset(self: *Worker, len: usize) !void {
        self.nodes.clearRetainingCapacity();
        self.tokens.clearRetainingCapacity();
        try self.end_heads.ensureTotalCapacity(self.allocator, len + 1);
        while (self.end_heads.items.len < len + 1) try self.end_heads.append(self.allocator, invalid_node);
        @memset(self.end_heads.items[0 .. len + 1], invalid_node);
    }

    fn resetCount(self: *Worker, len: usize) !void {
        self.count_nodes.clearRetainingCapacity();
        self.tokens.clearRetainingCapacity();
        try self.count_end_heads.ensureTotalCapacity(self.allocator, len + 1);
        while (self.count_end_heads.items.len < len + 1) try self.count_end_heads.append(self.allocator, invalid_node);
        @memset(self.count_end_heads.items[0 .. len + 1], invalid_node);
    }

    fn appendBestNode(self: *Worker, begin: usize, end: usize, candidate: Candidate) !void {
        const best = try self.findBestPrev(begin, candidate);
        const index = self.nodes.items.len;
        try self.nodes.append(self.allocator, .{
            .word_id = candidate.word_id,
            .start = begin,
            .end = end,
            .right_id = candidate.right_id,
            .min_cost = best.cost,
            .prev_node = best.index,
            .next_end = self.end_heads.items[end],
        });
        self.end_heads.items[end] = index;
    }

    inline fn appendBestCountNode(self: *Worker, begin: usize, end: usize, candidate: CountCandidate) !void {
        const best = try self.findBestCountPrev(begin, candidate);
        const token_count = self.count_nodes.items[best.index].token_count + 1;
        var existing_index = self.count_end_heads.items[end];
        while (existing_index != invalid_node) : (existing_index = self.count_nodes.items[existing_index].next_end) {
            var existing = &self.count_nodes.items[existing_index];
            if (existing.right_id != candidate.right_id) continue;
            if (best.cost > existing.min_cost) return;
            existing.min_cost = best.cost;
            existing.token_count = token_count;
            return;
        }
        const index = self.count_nodes.items.len;
        try self.count_nodes.append(self.allocator, .{
            .right_id = candidate.right_id,
            .min_cost = best.cost,
            .token_count = token_count,
            .next_end = self.count_end_heads.items[end],
        });
        self.count_end_heads.items[end] = index;
    }

    fn findBestPrev(self: *Worker, begin: usize, candidate: Candidate) !struct { index: usize, cost: i32 } {
        var best_index: ?usize = null;
        var best_cost: i32 = std.math.maxInt(i32);
        var prev_index = self.end_heads.items[begin];
        while (prev_index != invalid_node) : (prev_index = self.nodes.items[prev_index].next_end) {
            const prev = self.nodes.items[prev_index];
            const cost = prev.min_cost + self.dictionary.matrix.trustedCost(prev.right_id, candidate.left_id) + candidate.word_cost;
            if (best_index == null or cost <= best_cost) {
                best_index = prev_index;
                best_cost = cost;
            }
        }
        return .{ .index = best_index orelse return error.NoPath, .cost = best_cost };
    }

    inline fn findBestCountPrev(self: *Worker, begin: usize, candidate: CountCandidate) !struct { index: usize, cost: i32 } {
        const first_index = self.count_end_heads.items[begin];
        if (first_index == invalid_node) return error.NoPath;
        const first = self.count_nodes.items[first_index];
        if (first.next_end == invalid_node) {
            return .{
                .index = first_index,
                .cost = first.min_cost + self.dictionary.matrix.trustedCost(first.right_id, candidate.left_id) + candidate.word_cost,
            };
        }

        var best_index: usize = invalid_node;
        var best_cost: i32 = std.math.maxInt(i32);
        var prev_index = first_index;
        while (prev_index != invalid_node) : (prev_index = self.count_nodes.items[prev_index].next_end) {
            const prev = self.count_nodes.items[prev_index];
            const cost = prev.min_cost + self.dictionary.matrix.trustedCost(prev.right_id, candidate.left_id) + candidate.word_cost;
            if (best_index == invalid_node or cost <= best_cost) {
                best_index = prev_index;
                best_cost = cost;
            }
        }
        return .{ .index = best_index, .cost = best_cost };
    }

    fn bestEndNode(self: *Worker, end: usize) !usize {
        var best_index: ?usize = null;
        var best_cost: i32 = std.math.maxInt(i32);
        var index = self.end_heads.items[end];
        while (index != invalid_node) : (index = self.nodes.items[index].next_end) {
            const cost = self.nodes.items[index].min_cost;
            if (best_index == null or cost < best_cost) {
                best_index = index;
                best_cost = cost;
            }
        }
        return best_index orelse error.NoPath;
    }

    fn bestCountEndNode(self: *Worker, end: usize) !usize {
        var best_index: usize = invalid_node;
        var best_cost: i32 = std.math.maxInt(i32);
        var index = self.count_end_heads.items[end];
        while (index != invalid_node) : (index = self.count_nodes.items[index].next_end) {
            const cost = self.count_nodes.items[index].min_cost;
            if (best_index == invalid_node or cost < best_cost) {
                best_index = index;
                best_cost = cost;
            }
        }
        if (best_index == invalid_node) return error.NoPath;
        return best_index;
    }

    fn countPath(self: *const Worker, start_index: usize) usize {
        var count: usize = 0;
        var index = start_index;
        while (self.nodes.items[index].prev_node) |prev| {
            count += 1;
            index = prev;
        }
        return count;
    }

    fn backtrace(self: *Worker, input: []const u8, start_index: usize) !void {
        const count = self.countPath(start_index);

        try self.tokens.resize(self.allocator, count);
        var index = start_index;
        var out = count;
        while (self.nodes.items[index].prev_node) |prev| {
            out -= 1;
            const node = self.nodes.items[index];
            const feature = self.featureFor(node.word_id);
            self.tokens.items[out] = .{
                .start = node.start,
                .end = node.end,
                .word_id = node.word_id,
                .feature = feature,
                .total_cost = node.min_cost,
            };
            _ = input;
            index = prev;
        }
    }

    fn featureFor(self: *const Worker, word_id: u32) [:0]const u8 {
        if (word_id >= unknown_word_base) return self.dictionary.unk_entries[word_id - unknown_word_base].feature;
        if (word_id >= (1 << 30)) return self.dictionary.user_entries[word_id - (1 << 30)].feature;
        return self.dictionary.entries[word_id].feature;
    }
};

inline fn nextBoundary(input: []const u8, start: usize) ?usize {
    if (start >= input.len) return null;
    const byte = input[start];
    const len: usize = if (byte < 0x80)
        1
    else if ((byte & 0xe0) == 0xc0)
        2
    else if ((byte & 0xf0) == 0xe0)
        3
    else
        4;
    return start + len;
}

fn nthBoundary(input: []const u8, start: usize, n: usize) !usize {
    var end = start;
    var i: usize = 0;
    while (i < n) : (i += 1) end = nextBoundary(input, end) orelse return error.InvalidDictionary;
    return end;
}

inline fn nextCodepoint(input: []const u8, start: usize) ?u21 {
    if (start >= input.len) return null;
    const b0 = input[start];
    if (b0 < 0x80) return b0;

    const end = nextBoundary(input, start) orelse return null;
    if (end > input.len) return null;
    const bytes = input[start..end];
    return switch (bytes.len) {
        2 => (@as(u21, b0 & 0x1f) << 6) | @as(u21, bytes[1] & 0x3f),
        3 => (@as(u21, b0 & 0x0f) << 12) | (@as(u21, bytes[1] & 0x3f) << 6) | @as(u21, bytes[2] & 0x3f),
        4 => (@as(u21, b0 & 0x07) << 18) | (@as(u21, bytes[1] & 0x3f) << 12) | (@as(u21, bytes[2] & 0x3f) << 6) | @as(u21, bytes[3] & 0x3f),
        else => null,
    };
}

const GroupSpan = struct {
    end: usize,
    count: usize,
};

fn groupSpan(input: []const u8, start: usize, char_property: *const dict_mod.CharProperty, start_info: dict_mod.CharInfo) GroupSpan {
    var end = start;
    var count: usize = 0;
    while (end < input.len) {
        const ch = nextCodepoint(input, end) orelse break;
        const info = char_property.info(ch);
        if (!intersects(start_info.category_ids, info.category_ids)) break;
        end = nextBoundary(input, end) orelse break;
        count += 1;
    }
    return .{ .end = end, .count = count };
}

fn intersects(a: []const usize, b: []const usize) bool {
    for (a) |ai| for (b) |bi| if (ai == bi) return true;
    return false;
}

inline fn surfaceMatchesIndexed(input: []const u8, begin: usize, surface: []const u8) bool {
    if (surface.len > input.len - begin) return false;
    if (surface.len <= 1) return true;
    return std.mem.eql(u8, input[begin + 1 .. begin + surface.len], surface[1..]);
}

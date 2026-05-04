const std = @import("std");
const dict_mod = @import("dictionary.zig");
const tokenizer_mod = @import("tokenizer.zig");

const Dictionary = dict_mod.Dictionary;
const Tokenizer = tokenizer_mod.Tokenizer;
const Worker = tokenizer_mod.Worker;

var c_allocator = std.heap.page_allocator;
threadlocal var last_error_buf: [256]u8 = [_]u8{0} ** 256;

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrintZ(&last_error_buf, fmt, args) catch "error";
    @memset(last_error_buf[msg.len..], 0);
}

pub export fn delarocha_last_error() [*:0]const u8 {
    return @ptrCast(&last_error_buf);
}

pub export fn delarocha_tokenizer_new(path: [*:0]const u8) ?*Tokenizer {
    const tokenizer = c_allocator.create(Tokenizer) catch {
        setLastError("out of memory", .{});
        return null;
    };
    tokenizer.* = Tokenizer.initMinimalFile(c_allocator, std.mem.span(path)) catch |err| {
        c_allocator.destroy(tokenizer);
        setLastError("failed to load dictionary: {s}", .{@errorName(err)});
        return null;
    };
    return tokenizer;
}

pub export fn delarocha_tokenizer_new_raw(
    lex_path: [*:0]const u8,
    matrix_path: [*:0]const u8,
    char_path: [*:0]const u8,
    unk_path: [*:0]const u8,
) ?*Tokenizer {
    const tokenizer = c_allocator.create(Tokenizer) catch {
        setLastError("out of memory", .{});
        return null;
    };
    tokenizer.* = Tokenizer.initRawFiles(
        c_allocator,
        std.mem.span(lex_path),
        std.mem.span(matrix_path),
        std.mem.span(char_path),
        std.mem.span(unk_path),
    ) catch |err| {
        c_allocator.destroy(tokenizer);
        setLastError("failed to load raw dictionary: {s}", .{@errorName(err)});
        return null;
    };
    return tokenizer;
}

pub export fn delarocha_tokenizer_new_raw_count_only(
    lex_path: [*:0]const u8,
    matrix_path: [*:0]const u8,
    char_path: [*:0]const u8,
    unk_path: [*:0]const u8,
) ?*Tokenizer {
    const tokenizer = delarocha_tokenizer_new_raw(lex_path, matrix_path, char_path, unk_path) orelse return null;
    tokenizer.dictionary.discardFullTokenDataForCount();
    return tokenizer;
}

pub export fn delarocha_tokenizer_new_binary(path: [*:0]const u8) ?*Tokenizer {
    const tokenizer = c_allocator.create(Tokenizer) catch {
        setLastError("out of memory", .{});
        return null;
    };
    tokenizer.* = Tokenizer.initBinaryFile(c_allocator, std.mem.span(path)) catch |err| {
        c_allocator.destroy(tokenizer);
        setLastError("failed to load binary dictionary: {s}", .{@errorName(err)});
        return null;
    };
    return tokenizer;
}

pub export fn delarocha_tokenizer_new_binary_bytes(bytes_ptr: [*]const u8, bytes_len: usize) ?*Tokenizer {
    const tokenizer = c_allocator.create(Tokenizer) catch {
        setLastError("out of memory", .{});
        return null;
    };
    tokenizer.* = .{
        .allocator = c_allocator,
        .dictionary = Dictionary.fromBinaryBytes(c_allocator, bytes_ptr[0..bytes_len]) catch |err| {
            c_allocator.destroy(tokenizer);
            setLastError("failed to load binary dictionary bytes: {s}", .{@errorName(err)});
            return null;
        },
    };
    return tokenizer;
}

pub export fn delarocha_tokenizer_new_binary_count_only(path: [*:0]const u8) ?*Tokenizer {
    const tokenizer = delarocha_tokenizer_new_binary(path) orelse return null;
    tokenizer.dictionary.discardFullTokenDataForCount();
    return tokenizer;
}

pub export fn delarocha_dictionary_write_binary(
    lex_path: [*:0]const u8,
    matrix_path: [*:0]const u8,
    char_path: [*:0]const u8,
    unk_path: [*:0]const u8,
    output_path: [*:0]const u8,
) i32 {
    var dict = Dictionary.fromRawFiles(
        c_allocator,
        std.mem.span(lex_path),
        std.mem.span(matrix_path),
        std.mem.span(char_path),
        std.mem.span(unk_path),
    ) catch |err| {
        setLastError("failed to load raw dictionary: {s}", .{@errorName(err)});
        return -1;
    };
    defer dict.deinit();

    const bytes = dict.toBinaryAlloc(c_allocator) catch |err| {
        setLastError("failed to encode binary dictionary: {s}", .{@errorName(err)});
        return -1;
    };
    defer c_allocator.free(bytes);

    var io_instance: std.Io.Threaded = .init(c_allocator, .{});
    defer io_instance.deinit();
    std.Io.Dir.cwd().writeFile(io_instance.io(), .{
        .sub_path = std.mem.span(output_path),
        .data = bytes,
    }) catch |err| {
        setLastError("failed to write binary dictionary: {s}", .{@errorName(err)});
        return -1;
    };
    return 0;
}

pub export fn delarocha_tokenizer_free(tokenizer: ?*Tokenizer) void {
    if (tokenizer) |ptr| {
        ptr.deinit();
        c_allocator.destroy(ptr);
    }
}

pub export fn delarocha_worker_new(tokenizer: ?*Tokenizer) ?*Worker {
    const tokenizer_ptr = tokenizer orelse {
        setLastError("tokenizer is null", .{});
        return null;
    };
    const worker = c_allocator.create(Worker) catch {
        setLastError("out of memory", .{});
        return null;
    };
    worker.* = tokenizer_ptr.createWorker(c_allocator);
    return worker;
}

pub export fn delarocha_worker_free(worker: ?*Worker) void {
    if (worker) |ptr| {
        ptr.deinit();
        c_allocator.destroy(ptr);
    }
}

pub export fn delarocha_tokenize(worker: ?*Worker, input: [*:0]const u8) i32 {
    return tokenizeSlice(worker, std.mem.span(input));
}

pub export fn delarocha_tokenize_bytes(worker: ?*Worker, input: [*]const u8, len: usize) i32 {
    return tokenizeSlice(worker, input[0..len]);
}

pub export fn delarocha_tokenize_count_bytes(worker: ?*Worker, input: [*]const u8, len: usize) usize {
    const worker_ptr = worker orelse {
        setLastError("worker is null", .{});
        return std.math.maxInt(usize);
    };
    return tokenizeCountBytesNonnull(worker_ptr, input, len);
}

pub export fn delarocha_tokenize_count_bytes_nonnull(worker: *Worker, input: [*]const u8, len: usize) usize {
    return tokenizeCountBytesNonnull(worker, input, len);
}

fn tokenizeCountBytesNonnull(worker: *Worker, input: [*]const u8, len: usize) usize {
    return worker.tokenizeCountAssumeValid(input[0..len]);
}

pub export fn delarocha_tokenize_count_batch(
    worker: ?*Worker,
    inputs: [*]const [*]const u8,
    lens: [*]const usize,
    count: usize,
) usize {
    const worker_ptr = worker orelse {
        setLastError("worker is null", .{});
        return std.math.maxInt(usize);
    };
    return tokenizeCountBatchNonnull(worker_ptr, inputs, lens, count);
}

pub export fn delarocha_tokenize_count_batch_nonnull(
    worker: *Worker,
    inputs: [*]const [*]const u8,
    lens: [*]const usize,
    count: usize,
) usize {
    return tokenizeCountBatchNonnull(worker, inputs, lens, count);
}

fn tokenizeCountBatchNonnull(
    worker: *Worker,
    inputs: [*]const [*]const u8,
    lens: [*]const usize,
    count: usize,
) usize {
    var total: usize = 0;
    for (0..count) |i| {
        total +%= worker.tokenizeCountAssumeValid(inputs[i][0..lens[i]]);
    }
    return total;
}

fn tokenizeSlice(worker: ?*Worker, input: []const u8) i32 {
    const worker_ptr = worker orelse {
        setLastError("worker is null", .{});
        return -1;
    };
    _ = worker_ptr.tokenize(input) catch |err| {
        setLastError("tokenize failed: {s}", .{@errorName(err)});
        return -1;
    };
    return 0;
}

pub export fn delarocha_token_count(worker: ?*const Worker) usize {
    return if (worker) |ptr| ptr.tokens.items.len else 0;
}

pub export fn delarocha_token_surface_start(worker: ?*const Worker, index: usize) usize {
    return if (worker) |ptr| ptr.tokens.items[index].start else 0;
}

pub export fn delarocha_token_surface_end(worker: ?*const Worker, index: usize) usize {
    return if (worker) |ptr| ptr.tokens.items[index].end else 0;
}

pub export fn delarocha_token_word_id(worker: ?*const Worker, index: usize) u32 {
    return if (worker) |ptr| ptr.tokens.items[index].word_id else tokenizer_mod.unknown_word_id;
}

pub export fn delarocha_tokens_copy_spans(
    worker: ?*const Worker,
    starts: [*]usize,
    ends: [*]usize,
    word_ids: [*]u32,
    cap: usize,
) usize {
    const worker_ptr = worker orelse {
        setLastError("worker is null", .{});
        return std.math.maxInt(usize);
    };
    const tokens = worker_ptr.tokens.items;
    if (cap < tokens.len) {
        setLastError("token span output capacity is too small", .{});
        return std.math.maxInt(usize);
    }
    for (tokens, 0..) |token, index| {
        starts[index] = token.start;
        ends[index] = token.end;
        word_ids[index] = token.word_id;
    }
    return tokens.len;
}

pub export fn delarocha_token_feature(worker: ?*const Worker, index: usize) [*:0]const u8 {
    return if (worker) |ptr| ptr.tokens.items[index].feature else "UNK";
}

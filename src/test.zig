const std = @import("std");
const zlib = @import("root.zig");

const testing = std.testing;
const flate = std.compress.flate;

/// Text that compresses, with enough variety that matches are not trivial.
fn sample(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const words = [_][]const u8{ "alpha", "widget", "electronics", "price", "quantity", "rating", "tags", "sale", "{", "}", "\"", ":", ",", "12", "345", "\n" };
    const out = try allocator.alloc(u8, len);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    var i: usize = 0;
    while (i < len) {
        const word = words[prng.random().uintLessThan(usize, words.len)];
        const n = @min(word.len, len - i);
        @memcpy(out[i..][0..n], word[0..n]);
        i += n;
    }
    return out;
}

fn stdContainer(container: zlib.Container) flate.Container {
    return switch (container) {
        .raw => .raw,
        .zlib => .zlib,
        .gzip => .gzip,
    };
}

/// Inflates `compressed` with the standard library.
fn stdInflate(allocator: std.mem.Allocator, compressed: []const u8, container: zlib.Container) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var std_inflate: flate.Decompress = .init(&in, stdContainer(container), &window);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    _ = try std_inflate.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

/// Deflates `data` with the standard library.
fn stdDeflate(allocator: std.mem.Allocator, data: []const u8, container: zlib.Container) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
    errdefer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var std_deflate: flate.Compress = try .init(&out.writer, &window, stdContainer(container), .default);
    try std_deflate.writer.writeAll(data);
    try std_deflate.finish();
    return out.toOwnedSlice();
}

/// Deflates `data` with this library, writing it in `piece`-sized writes
/// through a writer buffer of `buffer_len`.
fn deflate(
    allocator: std.mem.Allocator,
    data: []const u8,
    container: zlib.Container,
    options: zlib.Options,
    buffer_len: usize,
    piece: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
    errdefer out.deinit();
    const buffer = try allocator.alloc(u8, buffer_len);
    defer allocator.free(buffer);
    var gz = try zlib.Compress.init(allocator, &out.writer, buffer, container, options);
    defer gz.deinit();
    var i: usize = 0;
    while (i < data.len) : (i += piece) {
        try gz.writer.writeAll(data[i..@min(i + piece, data.len)]);
    }
    try gz.finish();
    return out.toOwnedSlice();
}

/// Inflates `compressed` with this library through a reader buffer of
/// `buffer_len`.
fn inflate(allocator: std.mem.Allocator, compressed: []const u8, container: zlib.Container, buffer_len: usize) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    const buffer = try allocator.alloc(u8, buffer_len);
    defer allocator.free(buffer);
    var gz = try zlib.Decompress.init(allocator, &in, buffer, container, .{});
    defer gz.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    _ = try gz.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

test "Compress: the standard library inflates what it deflates, in every container" {
    const gpa = testing.allocator;
    const data = try sample(gpa, 50_000);
    defer gpa.free(data);

    for ([_]zlib.Container{ .raw, .zlib, .gzip }) |container| {
        const compressed = try deflate(gpa, data, container, .{}, 4096, 1000);
        defer gpa.free(compressed);
        try testing.expect(compressed.len < data.len / 2);
        const back = try stdInflate(gpa, compressed, container);
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, data, back);
    }
}

test "Compress: an unbuffered writer, a tiny one and single-byte writes all give the same stream" {
    const gpa = testing.allocator;
    const data = try sample(gpa, 20_000);
    defer gpa.free(data);

    const reference = try deflate(gpa, data, .gzip, .{}, 4096, data.len);
    defer gpa.free(reference);
    // zlib's output does not depend on how the input was split, so every
    // way of feeding it has to produce the same bytes.
    for ([_][2]usize{ .{ 0, 1 }, .{ 0, 777 }, .{ 7, 1 }, .{ 7, 13 }, .{ 64 * 1024, 3 } }) |shape| {
        const compressed = try deflate(gpa, data, .gzip, .{}, shape[0], shape[1]);
        defer gpa.free(compressed);
        try testing.expectEqualSlices(u8, reference, compressed);
    }
}

test "Compress: a large input, bigger than any buffer involved" {
    const gpa = testing.allocator;
    const data = try sample(gpa, 3 * 1024 * 1024);
    defer gpa.free(data);

    const compressed = try deflate(gpa, data, .zlib, .{ .level = .fastest }, 0, data.len);
    defer gpa.free(compressed);
    const back = try inflate(gpa, compressed, .zlib, 4096);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, data, back);
}

test "Compress: splats, of one byte and of a pattern" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer out.deinit();
    var gz = try zlib.Compress.init(gpa, &out.writer, &.{}, .gzip, .{});
    defer gz.deinit();

    try gz.writer.writeAll("<");
    try gz.writer.splatByteAll('x', 100_000);
    try gz.writer.splatBytesAll("ab", 1000);
    // `writeSplat` with a zero count writes none of the last element.
    _ = try gz.writer.writeSplat(&.{ "12", "zz" }, 0);
    try gz.writer.writeAll(">");
    try gz.finish();

    const back = try stdInflate(gpa, out.written(), .gzip);
    defer gpa.free(back);
    try testing.expectEqual(1 + 100_000 + 2000 + 2 + 1, back.len);
    try testing.expectEqual('<', back[0]);
    try testing.expect(std.mem.allEqual(u8, back[1..][0..100_000], 'x'));
    for (0..1000) |i| try testing.expectEqualStrings("ab", back[100_001 + 2 * i ..][0..2]);
    try testing.expectEqualStrings("12>", back[back.len - 3 ..]);
}

test "Compress: flush makes everything written so far decodable" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer out.deinit();
    var gz = try zlib.Compress.init(gpa, &out.writer, &.{}, .zlib, .{});
    defer gz.deinit();

    try gz.writer.writeAll("hello, ");
    try gz.writer.flush();

    // The stream is not finished, so reading stops for want of input, but
    // only after everything that was flushed.
    var in: std.Io.Reader = .fixed(out.written());
    var buf: [64]u8 = undefined;
    var reader = try zlib.Decompress.init(gpa, &in, &buf, .zlib, .{});
    defer reader.deinit();
    var got: [64]u8 = undefined;
    var got_writer: std.Io.Writer = .fixed(&got);
    const n = try reader.reader.stream(&got_writer, .unlimited);
    try testing.expectEqualStrings("hello, ", got[0..n]);
    // Asking for more finds the stream unfinished.
    try testing.expectError(error.ReadFailed, reader.reader.stream(&got_writer, .unlimited));
    try testing.expectEqual(error.TruncatedInput, reader.err.?);

    try gz.writer.writeAll("world");
    try gz.finish();
    const back = try stdInflate(gpa, out.written(), .zlib);
    defer gpa.free(back);
    try testing.expectEqualStrings("hello, world", back);
}

test "Compress: reset starts a fresh stream without allocating" {
    var fixed: [512 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fixed);
    const allocator = fba.allocator();

    var out1: [4096]u8 = undefined;
    var out2: [4096]u8 = undefined;
    var w1: std.Io.Writer = .fixed(&out1);
    var w2: std.Io.Writer = .fixed(&out2);

    var gz = try zlib.Compress.init(allocator, &w1, &.{}, .gzip, .{});
    defer gz.deinit();
    try gz.writer.writeAll("first stream, first stream");
    try gz.finish();
    try testing.expectError(error.WriteFailed, gz.writer.writeAll("after finish"));
    try testing.expectEqual(error.WriteAfterFinish, gz.err.?);

    const used = fba.end_index;
    gz.reset(&w2);
    try testing.expectEqual(null, gz.err);
    try gz.writer.writeAll("second");
    try gz.finish();
    try testing.expectEqual(used, fba.end_index);

    const a = try stdInflate(testing.allocator, w1.buffered(), .gzip);
    defer testing.allocator.free(a);
    const b = try stdInflate(testing.allocator, w2.buffered(), .gzip);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("first stream, first stream", a);
    try testing.expectEqualStrings("second", b);
}

test "Compress: small windows, a low memory level and other strategies still round-trip" {
    const gpa = testing.allocator;
    const data = try sample(gpa, 30_000);
    defer gpa.free(data);

    const cases = [_]zlib.Options{
        .{ .window_bits = 9, .mem_level = 1 },
        .{ .window_bits = 12, .mem_level = 5, .level = .fastest },
        .{ .level = .no_compression },
        .{ .level = .best },
        .{ .level = .of(3), .strategy = .filtered },
        .{ .strategy = .huffman_only },
        .{ .strategy = .rle },
        .{ .strategy = .fixed },
    };
    for (cases) |options| {
        const compressed = try deflate(gpa, data, .gzip, options, 256, 4000);
        defer gpa.free(compressed);
        const back = try stdInflate(gpa, compressed, .gzip);
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, data, back);
    }
}

test "Decompress: inflates what the standard library deflates, in every container" {
    const gpa = testing.allocator;
    const data = try sample(gpa, 50_000);
    defer gpa.free(data);

    for ([_]zlib.Container{ .raw, .zlib, .gzip }) |container| {
        const compressed = try stdDeflate(gpa, data, container);
        defer gpa.free(compressed);
        for ([_]usize{ 1, 100, 64 * 1024 }) |buffer_len| {
            const back = try inflate(gpa, compressed, container, buffer_len);
            defer gpa.free(back);
            try testing.expectEqualSlices(u8, data, back);
        }
    }
}

test "Decompress: reads through a small input buffer, and respects a limit" {
    const gpa = testing.allocator;
    const data = try sample(gpa, 40_000);
    defer gpa.free(data);
    const compressed = try deflate(gpa, data, .gzip, .{}, 4096, data.len);
    defer gpa.free(compressed);

    // An input that hands out a few bytes at a time.
    var in_storage: std.Io.Reader = .fixed(compressed);
    var small: [5]u8 = undefined;
    var in = in_storage.limited(.unlimited, &small);

    var buf: [128]u8 = undefined;
    var gz = try zlib.Decompress.init(gpa, &in.interface, &buf, .gzip, .{});
    defer gz.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const first = try gz.reader.stream(&out.writer, .limited(10));
    try testing.expect(first <= 10);
    _ = try gz.reader.streamRemaining(&out.writer);
    try testing.expectEqualSlices(u8, data, out.written());
}

test "Decompress: leaves what follows the stream in the input" {
    const gpa = testing.allocator;
    const compressed = try deflate(gpa, "payload", .zlib, .{}, 0, 7);
    defer gpa.free(compressed);
    const framed = try std.mem.concat(gpa, u8, &.{ compressed, "TRAILER" });
    defer gpa.free(framed);

    var in: std.Io.Reader = .fixed(framed);
    var buf: [64]u8 = undefined;
    var gz = try zlib.Decompress.init(gpa, &in, &buf, .zlib, .{});
    defer gz.deinit();
    var out: [64]u8 = undefined;
    const n = try gz.reader.readSliceShort(&out);
    try testing.expectEqualStrings("payload", out[0..n]);
    try testing.expectEqualStrings("TRAILER", in.buffered());
}

test "Decompress: corrupt and truncated input fail with the reason recorded" {
    const gpa = testing.allocator;
    const data = try sample(gpa, 5000);
    defer gpa.free(data);
    const compressed = try deflate(gpa, data, .gzip, .{}, 0, data.len);
    defer gpa.free(compressed);

    {
        const bad = try gpa.dupe(u8, compressed);
        defer gpa.free(bad);
        // The CRC in the trailer.
        bad[bad.len - 6] ^= 0xff;
        var in: std.Io.Reader = .fixed(bad);
        var buf: [256]u8 = undefined;
        var gz = try zlib.Decompress.init(gpa, &in, &buf, .gzip, .{});
        defer gz.deinit();
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, gz.reader.streamRemaining(&out.writer));
        try testing.expectEqual(error.CorruptInput, gz.err.?);
    }
    {
        var in: std.Io.Reader = .fixed(compressed[0 .. compressed.len / 2]);
        var buf: [256]u8 = undefined;
        var gz = try zlib.Decompress.init(gpa, &in, &buf, .gzip, .{});
        defer gz.deinit();
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, gz.reader.streamRemaining(&out.writer));
        try testing.expectEqual(error.TruncatedInput, gz.err.?);
    }
    {
        var in: std.Io.Reader = .fixed("definitely not gzip");
        var buf: [256]u8 = undefined;
        var gz = try zlib.Decompress.init(gpa, &in, &buf, .gzip, .{});
        defer gz.deinit();
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, gz.reader.streamRemaining(&out.writer));
        try testing.expectEqual(error.CorruptInput, gz.err.?);
    }
}

test "Decompress: reset reads a second stream without allocating" {
    var fixed: [256 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fixed);
    const allocator = fba.allocator();

    const a = try deflate(testing.allocator, "one", .gzip, .{}, 0, 3);
    defer testing.allocator.free(a);
    const b = try deflate(testing.allocator, "two", .gzip, .{}, 0, 3);
    defer testing.allocator.free(b);

    var in_a: std.Io.Reader = .fixed(a);
    var in_b: std.Io.Reader = .fixed(b);
    var buf: [64]u8 = undefined;
    var gz = try zlib.Decompress.init(allocator, &in_a, &buf, .gzip, .{});
    defer gz.deinit();
    var out: [16]u8 = undefined;
    try testing.expectEqualStrings("one", out[0..try gz.reader.readSliceShort(&out)]);

    const used = fba.end_index;
    gz.reset(&in_b);
    try testing.expectEqualStrings("two", out[0..try gz.reader.readSliceShort(&out)]);
    try testing.expectEqual(used, fba.end_index);
}

test "Compress and Decompress stay small: the state lives behind a pointer" {
    try testing.expect(@sizeOf(zlib.Compress) <= 64);
    try testing.expect(@sizeOf(zlib.Decompress) <= 96);
}

test "Compress: output failing is recorded as WriteFailed, for its own error to explain" {
    const gpa = testing.allocator;
    // Stored, so more than zlib holds back before writing a block.
    const data = try sample(gpa, 200_000);
    defer gpa.free(data);

    // Too small for the compressed stream, so it fails part way through.
    var small: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&small);
    var gz = try zlib.Compress.init(gpa, &out, &.{}, .gzip, .{ .level = .no_compression });
    defer gz.deinit();

    try testing.expectError(error.WriteFailed, gz.writer.writeAll(data));
    try testing.expectEqual(error.WriteFailed, gz.err.?);
    // And stays failed.
    try testing.expectError(error.WriteFailed, gz.writer.writeAll("more"));
    try testing.expectError(error.WriteFailed, gz.finish());
}

test "Decompress: input failing is recorded as ReadFailed, for its own error to explain" {
    const gpa = testing.allocator;
    var in_buf: [16]u8 = undefined;
    var in: std.Io.Reader = .{ .vtable = std.Io.Reader.failing.vtable, .buffer = &in_buf, .seek = 0, .end = 0 };
    var buf: [64]u8 = undefined;
    var gz = try zlib.Decompress.init(gpa, &in, &buf, .gzip, .{});
    defer gz.deinit();

    var out: [16]u8 = undefined;
    try testing.expectError(error.ReadFailed, gz.reader.readSliceShort(&out));
    try testing.expectEqual(error.ReadFailed, gz.err.?);
}

test "Decompress: the writer being read into failing is not the reader's error" {
    const gpa = testing.allocator;
    const data = try sample(gpa, 5000);
    defer gpa.free(data);
    const compressed = try deflate(gpa, data, .gzip, .{}, 0, data.len);
    defer gpa.free(compressed);

    var in: std.Io.Reader = .fixed(compressed);
    var buf: [64]u8 = undefined;
    var gz = try zlib.Decompress.init(gpa, &in, &buf, .gzip, .{});
    defer gz.deinit();

    var dest: std.Io.Writer = .failing;
    try testing.expectError(error.WriteFailed, gz.reader.streamRemaining(&dest));
    try testing.expectEqual(null, gz.err);
}

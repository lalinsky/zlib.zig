//! zlib, behind `std.Io.Writer` and `std.Io.Reader`.
//!
//! `Compress` is a writer that deflates what is written to it into another
//! writer; `Decompress` is a reader that inflates what it reads from another
//! reader. zlib keeps its state and window behind a pointer, allocated from
//! the allocator given to `init`, so neither struct holds anything large and
//! either can live anywhere, including a small coroutine stack.
//!
//! ```zig
//! var gz = try zlib.Compress.init(allocator, &out.writer, &.{}, .gzip, .{});
//! defer gz.deinit();
//! try gz.writer.writeAll(body);
//! try gz.finish();
//! ```

const std = @import("std");
const c = @import("c");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

/// The framing around the deflate stream, as `std.compress.flate.Container`.
pub const Container = enum {
    /// A bare deflate stream, no header or checksum.
    raw,
    /// RFC 1950: two bytes of header, an Adler-32 at the end.
    zlib,
    /// RFC 1952: a gzip header, a CRC-32 and the length at the end.
    gzip,

    /// zlib's `windowBits`, which also picks the framing.
    fn windowBits(container: Container, window_bits: u4) c_int {
        std.debug.assert(window_bits >= 9 and window_bits <= 15);
        const bits: c_int = window_bits;
        return switch (container) {
            .raw => -bits,
            .zlib => bits,
            .gzip => bits + 16,
        };
    }
};

/// How hard to look for matches: 0 stores, 1 is fastest, 9 compresses best.
pub const Level = enum(c_int) {
    no_compression = 0,
    fastest = 1,
    best = 9,
    /// zlib's default, currently 6.
    default = -1,
    _,

    /// A numeric level, 0 to 9.
    pub fn of(n: u4) Level {
        std.debug.assert(n <= 9);
        return @enumFromInt(n);
    }
};

pub const Strategy = enum(c_int) {
    default = c.Z_DEFAULT_STRATEGY,
    /// For data made of small values with a somewhat random distribution.
    filtered = c.Z_FILTERED,
    /// No string matching, only Huffman coding.
    huffman_only = c.Z_HUFFMAN_ONLY,
    /// Matches of distance one only: runs of the same byte.
    rle = c.Z_RLE,
    /// No dynamic Huffman codes.
    fixed = c.Z_FIXED,
};

/// The memory zlib uses is set by `window_bits` and `mem_level`. Deflate
/// takes about `(1 << (window_bits + 2)) + (1 << (mem_level + 9))` bytes:
/// 256K at the defaults, 20K at `window_bits = 12, mem_level = 5`, which
/// loses little on inputs of a few kilobytes. Inflate takes about
/// `1 << window_bits` plus 7K.
pub const Options = struct {
    level: Level = .default,
    /// Log2 of the window, 9 to 15. A match reaches at most this far back.
    window_bits: u4 = 15,
    /// Memory for the match finder's hash table and pending output, 1 to 9.
    mem_level: u4 = 8,
    strategy: Strategy = .default,
};

/// Where zlib's own allocations come from: `init` puts the allocator here,
/// and zlib hands this back to `zalloc` and `zfree`.
const State = struct {
    stream: c.z_stream,
    allocator: Allocator,

    fn create(allocator: Allocator) Allocator.Error!*State {
        const state = try allocator.create(State);
        state.* = .{ .stream = std.mem.zeroes(c.z_stream), .allocator = allocator };
        state.stream.zalloc = zalloc;
        state.stream.zfree = zfree;
        state.stream.@"opaque" = state;
        return state;
    }

    /// zlib only gives `zfree` the address, so each allocation carries its
    /// length in front of it, in a header that keeps the rest aligned.
    const header_len = 16;
    const alignment: std.mem.Alignment = .@"16";

    fn zalloc(state_ptr: ?*anyopaque, items: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
        const state: *State = @ptrCast(@alignCast(state_ptr.?));
        const len = std.math.mul(usize, items, size) catch return null;
        const total = std.math.add(usize, len, header_len) catch return null;
        const memory = state.allocator.alignedAlloc(u8, alignment, total) catch return null;
        @as(*usize, @ptrCast(memory.ptr)).* = total;
        return memory.ptr + header_len;
    }

    fn zfree(state_ptr: ?*anyopaque, address: ?*anyopaque) callconv(.c) void {
        const state: *State = @ptrCast(@alignCast(state_ptr.?));
        const base: [*]align(alignment.toByteUnits()) u8 = @alignCast(@as([*]u8, @ptrCast(address orelse return)) - header_len);
        const total = @as(*usize, @ptrCast(base)).*;
        state.allocator.free(base[0..total]);
    }
};

/// A writer that deflates into `output`.
///
/// `flush` sends everything written so far through to `output`, byte
/// aligned, so what is there decodes up to that point, as the flush of
/// `std.compress.flate.Compress` does; it costs a few bytes each time.
/// `finish` ends the stream. Neither flushes `output` itself, which has to
/// have a buffer: compressed bytes are written straight into it.
///
/// A failure is recorded in `err`, as the interface can only report
/// `error.WriteFailed`; `error.WriteFailed` there means `output` failed, and
/// `output`'s own error has the cause.
pub const Compress = struct {
    /// Written to. Its buffer is only where writes wait before reaching
    /// zlib, which keeps its own window, so any size will do, including
    /// none: then every write goes to zlib as it is, without a copy.
    writer: Writer,
    output: *Writer,
    state: *State,
    finished: bool = false,
    /// Why a write failed with `error.WriteFailed`. Until `reset`, every
    /// write after a failure fails too.
    err: ?Error = null,

    pub const Error = error{
        /// `output` failed: its own error says why.
        WriteFailed,
        /// Written to after `finish`, without a `reset`.
        WriteAfterFinish,
    };

    pub fn init(
        allocator: Allocator,
        output: *Writer,
        buffer: []u8,
        container: Container,
        options: Options,
    ) Allocator.Error!Compress {
        // Compressed bytes are written straight into its buffer.
        std.debug.assert(output.buffer.len > 0);
        std.debug.assert(options.mem_level >= 1 and options.mem_level <= 9);
        const state = try State.create(allocator);
        errdefer allocator.destroy(state);
        switch (c.deflateInit2_(
            &state.stream,
            @intFromEnum(options.level),
            c.Z_DEFLATED,
            container.windowBits(options.window_bits),
            options.mem_level,
            @intFromEnum(options.strategy),
            c.ZLIB_VERSION,
            @sizeOf(c.z_stream),
        )) {
            c.Z_OK => {},
            c.Z_MEM_ERROR => return error.OutOfMemory,
            // The options are checked above, and the header is the one
            // compiled with.
            else => unreachable,
        }
        return .{
            .writer = .{ .buffer = buffer, .vtable = &vtable },
            .output = output,
            .state = state,
        };
    }

    /// Frees zlib's state. Whatever was written and not finished is lost.
    pub fn deinit(self: *Compress) void {
        _ = c.deflateEnd(&self.state.stream);
        self.state.allocator.destroy(self.state);
        self.* = undefined;
    }

    /// Starts a new stream into `output`, with the same options and
    /// without allocating again.
    pub fn reset(self: *Compress, output: *Writer) void {
        std.debug.assert(c.deflateReset(&self.state.stream) == c.Z_OK);
        self.output = output;
        self.writer.end = 0;
        self.finished = false;
        self.err = null;
    }

    /// Ends the stream: the rest of what was written, and the container's
    /// trailer, go to `output`. Writing after this fails until `reset`.
    pub fn finish(self: *Compress) Writer.Error!void {
        try self.check();
        self.finished = true;
        try self.deflate(self.writer.buffered(), c.Z_FINISH);
        self.writer.end = 0;
    }

    const vtable: Writer.VTable = .{
        .drain = drain,
        .flush = flush,
    };

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Compress = @alignCast(@fieldParentPtr("writer", w));
        try self.check();
        try self.deflate(w.buffered(), c.Z_NO_FLUSH);
        w.end = 0;

        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.deflate(bytes, c.Z_NO_FLUSH);
            written += bytes.len;
        }
        const pattern = data[data.len - 1];
        switch (pattern.len) {
            0 => {},
            1 => {
                // A run of one byte, in pieces rather than a call per byte.
                var run: [256]u8 = undefined;
                @memset(&run, pattern[0]);
                var left = splat;
                while (left > 0) {
                    const n = @min(left, run.len);
                    try self.deflate(run[0..n], c.Z_NO_FLUSH);
                    left -= n;
                }
            },
            else => for (0..splat) |_| try self.deflate(pattern, c.Z_NO_FLUSH),
        }
        written += pattern.len * splat;
        return written;
    }

    fn flush(w: *Writer) Writer.Error!void {
        const self: *Compress = @alignCast(@fieldParentPtr("writer", w));
        try self.check();
        try self.deflate(w.buffered(), c.Z_SYNC_FLUSH);
        w.end = 0;
    }

    /// Fails as the last failure did, or for a write after `finish`.
    fn check(self: *Compress) Writer.Error!void {
        if (self.err != null) return error.WriteFailed;
        if (self.finished) return self.fail(error.WriteAfterFinish);
    }

    fn fail(self: *Compress, err: Error) error{WriteFailed} {
        self.err = err;
        return error.WriteFailed;
    }

    /// Feeds `input` to zlib and passes on what it produces. With
    /// `Z_NO_FLUSH` it returns once zlib has taken all of `input`, with
    /// `Z_SYNC_FLUSH` once zlib has nothing more to give for it, and with
    /// `Z_FINISH` once the stream has ended.
    fn deflate(self: *Compress, input: []const u8, mode: c_int) Writer.Error!void {
        if (input.len == 0 and mode == c.Z_NO_FLUSH) return;
        const stream = &self.state.stream;
        var rest = input;
        while (true) {
            const chunk = @min(rest.len, std.math.maxInt(c_uint));
            const last = chunk == rest.len;
            stream.next_in = rest.ptr;
            stream.avail_in = @intCast(chunk);
            // Only the call with the last of the input carries the flush.
            const flush_mode = if (last) mode else c.Z_NO_FLUSH;
            while (true) {
                const out = self.output.writableSliceGreedy(1) catch return self.fail(error.WriteFailed);
                const room: c_uint = @intCast(@min(out.len, std.math.maxInt(c_uint)));
                stream.next_out = out.ptr;
                stream.avail_out = room;
                const rc = c.deflate(stream, flush_mode);
                self.output.advance(room - stream.avail_out);
                switch (rc) {
                    c.Z_STREAM_END => return,
                    // No progress possible, which with input consumed and
                    // nothing pending is done.
                    c.Z_OK, c.Z_BUF_ERROR => {},
                    else => unreachable,
                }
                if (stream.avail_in != 0) continue;
                // Output space left over means zlib had nothing more.
                if (flush_mode == c.Z_NO_FLUSH or (flush_mode == c.Z_SYNC_FLUSH and stream.avail_out != 0)) break;
            }
            rest = rest[chunk..];
            if (last) return;
        }
    }
};

/// A reader that inflates what it reads from `input`.
///
/// It stops at the end of the deflate stream and its container, leaving
/// whatever follows in `input`, which has to have a buffer: compressed bytes
/// are read straight out of it.
///
/// A failure is recorded in `err`, as the interface can only report
/// `error.ReadFailed`; `error.ReadFailed` there means `input` failed, and
/// `input`'s own error has the cause.
pub const Decompress = struct {
    reader: Reader,
    input: *Reader,
    state: *State,
    done: bool = false,
    /// Why a read failed with `error.ReadFailed`. Until `reset`, every read
    /// after a failure fails too. A `WriteFailed` from the writer being read
    /// into is that writer's to explain, and is not recorded here.
    err: ?Error = null,

    pub const Error = error{
        /// `input` failed: its own error says why.
        ReadFailed,
        /// Not a valid stream in the expected container, or a checksum that
        /// does not match.
        CorruptInput,
        /// `input` ended before the stream did.
        TruncatedInput,
        OutOfMemory,
    };

    pub const Options = struct {
        /// At least the window the stream was compressed with. 15 accepts
        /// any zlib or gzip stream; a raw stream has to be told.
        window_bits: u4 = 15,
    };

    /// `buffer` is the reader's own buffer, as for any `std.Io.Reader`.
    /// zlib keeps its window apart from it, so its size is only about how
    /// much a caller wants to peek at once.
    pub fn init(
        allocator: Allocator,
        input: *Reader,
        buffer: []u8,
        container: Container,
        options: Decompress.Options,
    ) Allocator.Error!Decompress {
        // Compressed bytes are read straight out of its buffer.
        std.debug.assert(input.buffer.len > 0);
        const state = try State.create(allocator);
        errdefer allocator.destroy(state);
        switch (c.inflateInit2_(
            &state.stream,
            container.windowBits(options.window_bits),
            c.ZLIB_VERSION,
            @sizeOf(c.z_stream),
        )) {
            c.Z_OK => {},
            c.Z_MEM_ERROR => return error.OutOfMemory,
            else => unreachable,
        }
        return .{
            .reader = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &vtable },
            .input = input,
            .state = state,
        };
    }

    pub fn deinit(self: *Decompress) void {
        _ = c.inflateEnd(&self.state.stream);
        self.state.allocator.destroy(self.state);
        self.* = undefined;
    }

    /// Starts reading a new stream from `input`, without allocating again.
    pub fn reset(self: *Decompress, input: *Reader) void {
        std.debug.assert(c.inflateReset(&self.state.stream) == c.Z_OK);
        self.input = input;
        self.reader.seek = 0;
        self.reader.end = 0;
        self.done = false;
        self.err = null;
    }

    const vtable: Reader.VTable = .{ .stream = stream };

    fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *Decompress = @alignCast(@fieldParentPtr("reader", r));
        if (self.done) return error.EndOfStream;
        if (self.err != null) return error.ReadFailed;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;

        const z = &self.state.stream;
        while (true) {
            if (self.input.bufferedLen() == 0) {
                self.input.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return self.fail(error.TruncatedInput),
                    error.ReadFailed => return self.fail(error.ReadFailed),
                };
            }
            const in = self.input.buffered();
            const in_len: c_uint = @intCast(@min(in.len, std.math.maxInt(c_uint)));
            const room: c_uint = @intCast(@min(dest.len, std.math.maxInt(c_uint)));
            z.next_in = in.ptr;
            z.avail_in = in_len;
            z.next_out = dest.ptr;
            z.avail_out = room;
            const rc = c.inflate(z, c.Z_NO_FLUSH);
            self.input.toss(in_len - z.avail_in);
            const produced = room - z.avail_out;
            w.advance(produced);
            switch (rc) {
                c.Z_STREAM_END => {
                    self.done = true;
                    if (produced == 0) return error.EndOfStream;
                    return produced;
                },
                // `Z_BUF_ERROR` is no progress for want of input, which the
                // next pass reads.
                c.Z_OK, c.Z_BUF_ERROR => if (produced > 0) return produced,
                c.Z_MEM_ERROR => return self.fail(error.OutOfMemory),
                // A preset dictionary is not something this reader offers.
                c.Z_DATA_ERROR, c.Z_NEED_DICT => return self.fail(error.CorruptInput),
                else => unreachable,
            }
        }
    }

    fn fail(self: *Decompress, err: Error) error{ReadFailed} {
        self.err = err;
        return error.ReadFailed;
    }
};

test {
    _ = @import("test.zig");
}

zlib for Zig, behind `std.Io.Writer` and `std.Io.Reader`.

It builds [zlib](https://zlib.net) 1.3.2 from vendored sources with the Zig
build system, so there is nothing to install and cross-compiling works, and
wraps it in the same shape as `std.compress.flate`: a `Compress` that is a
writer and a `Decompress` that is a reader.

Unlike `std.compress.flate`, the compressor's state is not a value you hold.
zlib allocates it from the allocator you pass, so `Compress` and
`Decompress` are a few words each and fine on any stack, and the state can be
sized to the data with `window_bits` and `mem_level` instead of always being
the largest.

## Installation

```sh
zig fetch --save "git+https://github.com/lalinsky/zlib.zig"
```

```zig
const zlib = b.dependency("zlib", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zlib", zlib.module("zlib"));
```

## Compressing

```zig
const zlib = @import("zlib");

var gz = try zlib.Compress.init(allocator, &out.writer, &.{}, .gzip, .{});
defer gz.deinit();
try gz.writer.writeAll(body);
try gz.finish();
```

- The container is `.raw`, `.zlib` or `.gzip`.
- The writer's buffer (`&.{}` above) is only where writes wait before
  reaching zlib, which keeps its own window, so it can be any size, including
  none. `output` has to have a buffer: compressed bytes are written into it.
- `flush` pushes everything written so far through to `output`, so it can be
  decoded up to there. `finish` ends the stream. Neither flushes `output`.
- `reset` starts a new stream with the same state, without allocating, for
  reusing a compressor from a pool.

Options:

```zig
.{
    .level = .default,     // .no_compression, .fastest, .best, or .of(0...9)
    .window_bits = 15,     // 9...15
    .mem_level = 8,        // 1...9
    .strategy = .default,  // .filtered, .huffman_only, .rle, .fixed
}
```

Deflate uses about `(1 << (window_bits + 2)) + (1 << (mem_level + 9))`
bytes: 256K at the defaults, 20K at `window_bits = 12, mem_level = 5`, which
loses little on inputs of a few kilobytes.

## Decompressing

```zig
var gz = try zlib.Decompress.init(allocator, &in, &buffer, .gzip, .{});
defer gz.deinit();
const body = try gz.reader.allocRemaining(allocator, .limited(max_len));
```

It stops at the end of the stream and its container and leaves what follows
in `in`, which has to have a buffer.

## Errors

The `std.Io` interfaces can only fail with `error.WriteFailed` or
`error.ReadFailed`, so each wrapper keeps the cause in `err`:

- `Compress.err`: `error.WriteFailed` when `output` failed, and `output`'s
  own error says why; `error.WriteAfterFinish`.
- `Decompress.err`: `error.ReadFailed` when `in` failed, and `in`'s own error
  says why; `error.CorruptInput`, `error.TruncatedInput`, `error.OutOfMemory`.

A failure stays until `reset`.

## License

MIT for this wrapper. zlib is under the [zlib license](vendor/zlib/LICENSE).

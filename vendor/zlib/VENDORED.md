zlib 1.3.2, from https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz

- sha256 of the tarball: bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
- signature `zlib-1.3.2.tar.gz.asc` verified against Mark Adler's key
  5ED4 6A67 21D3 6558 7791  E2AA 783F CD8E 58BC AFBA

Only the library sources are kept: the `gz*` file I/O (except `gzguts.h`,
which `zutil.c` includes), contrib, examples,
tests and platform build files are left out. The files are unmodified.

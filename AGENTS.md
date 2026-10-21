# AGENTS.md

## Toolchain: build with Zig 0.17

The dependencies (`httpx` 0.2.2 and `zig-curl`) both declare
`minimum_zig_version = "0.17.0"`, so the project only builds under Zig 0.17.

- Build/test with the project-local wrapper: `./zig build`, `./zig build test`.
- It pins to a 0.17 toolchain (set `ZIG_17` to override, e.g. `/snap/zig/17037/zig`).
- Both deps are **local path dependencies** in `build.zig.zon`:
  `curl -> ../zig-curl` and `httpx -> ../httpx.zig`. They must exist as siblings
  of this checkout. If a sibling is missing, the `./zig` wrapper clones it from
  GitHub at the pinned commit before building (override the pin via the
  `ZIG_CURL_REF`/`HTTPX_REF` env vars). A sibling that has a `build.zig.zon` is
  treated as present and left alone, so a local pin/edit survives; CI still
  checks both out as siblings, so the bootstrap is a no-op there.
- Do not switch `httpx` back to a URL dep: GitHub tarballs extract to a nested
  `httpx.zig-X/` wrapper that Zig 0.17's build graph hashes incorrectly
  (`N-V-__...` content hash), so the pinned hash never matches. The bootstrap
  uses `git clone` (not a tarball) precisely to avoid that wrapper.

## Zig 0.17 language/toolchain quirks in this codebase

Confirmed against the 0.17 toolchain. Avoid these (they do not compile):

- **No backtick multiline string literals.** `` `...` `` is rejected. Use regular
  `"..."` strings (concatenate with `++` if needed).
- **Keyword identifiers use `@"name"`, not `r#name` — except for struct
  fields, where bare `type` is canonical.** A local or function parameter named
  `type` must be `@"type"` (a local `const type = 1` is a compile error). A
  struct field whose JSON key is `type` is declared bare — `type: []const u8`
  — and accessed `p.type`; `zig fmt` rewrites `@"type"` field spellings to bare
  `type`, so keep fields bare. (`buildPathMapping` illustrates the mix: its
  parameter is `@"type"`, the `PathMapping`/`RawPathMapping` fields are `type`.)
  `r#type` is a parse error here.
- **`std.json.fromJson` does not exist.** Use `std.json.parseFromSliceLeaky(T,
  allocator, bytes, .{ .allocate = .alloc_always })` (returns `T`, strings owned
  by the allocator) or `std.json.parseFromSlice(...)` (returns `Parsed(T)` which
  owns its own arena and must be kept alive / `deinit`ed).
- **File I/O needs an `std.Io` instance** (from `std.process.Init.io`, or
  `httpx.IoContext.init(allocator).io` in tests). There is no `std.fs.cwd`:
  - read: `std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited)`
  - write: `std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf, .flags = .{} })`
  - delete: `std.Io.Dir.cwd().deleteFile(io, path)`
- **`b.args` is gone from `std.Build`.** To forward CLI args to a run artifact,
  call `run_cmd.addPassthruArgs()` (no `if (b.args)`).
- **A bare `-Dtarget=x86_64-linux` (no libc version) leaves the
  system-library search paths empty.** Linking a system lib then fails with
  `unable to find dynamic system library "curl" ... searched paths: none`
  (in zig-curl's translate-c step). For native builds that link system
  libraries, omit `-Dtarget` so the host default target is used — it carries
  the glibc version (e.g. `x86_64-linux.7.0...7.0-gnu.2.39`). Cross targets
  and vendored builds are unaffected (they link no system libraries).
- **`std.builtin.Optimize` fields are lowercase** (`debug`, `safe`, `fast`,
  `small`). The old `.ReleaseFast`/`.Debug` are deprecated comptime aliases that
  do NOT resolve in `==` comparisons or leading-dot positions — use `.fast` and
  `.debug`.
- **`\0` is not a valid string-literal escape.** Build NUL-terminated C strings
  with a byte array: `const s = [_]u8{ 'a', 'b', 0 };` then pass `&s[0]`.
- **Array `.ptr` is not available** for a `[N]T` in this toolchain; take
  `&arr[0]` instead.
- **zig-curl 0.17 `Easy` hides its raw handle.** `Easy` no longer exposes
  `cHandle()`/`diagnosticsRef()` and has no header-function setter. `forward.zig`
  therefore drives the raw bindings directly via `curl.libcurl` (`curl_easy_*`,
  `curl_slist_*`) and `curl.checkCode` + a local `curl.Diagnostics{}`. The
  `Easy` type is still used only for its `HttpVersion` enum.
- **The vendored libcurl has no HTTP/2.** `link_vendor=true` (zig-curl) compiles
  libcurl + mbedtls + zlib but not nghttp2, so it is built without `USE_HTTP2`.
  There, `setopt(CURLOPT_HTTP_VERSION, 2TLS/2_0)` fails with `CURLE_NOT_BUILT_IN`.
  `forward.zig` detects this at startup via `curl_version_info` (`nghttp2_version
  != null`): when absent, `"auto"` maps straight to HTTP/1.1 and an explicit
  `"http2"` protocol is refused at startup. This is why the release (vendored)
  binaries are HTTP/1.1-only upstream while dev/system-libcurl builds can do
  HTTP/2. Do not "fix" this by assuming `auto` always requests 2TLS.

## Release / binary size

- Release artifacts are built on a single Linux runner and **stripped** (see
  `strip` in `build.zig`); a `-vendored` suffix marks the artifacts that link
  the vendored libcurl. `x86_64-linux` (runner's system libcurl — keeps
  HTTP/2, dynamic glibc/libcurl/OpenSSL deps), `x86_64-linux-vendored`
  (vendored libcurl, fully static), `aarch64-macos-vendored` (vendored,
  cross-compiled; no x86_64-macos target). Zig 0.17's ELF linker embeds full
  DWARF in release
  artifacts by default, so an unstripped x86_64-linux release binary is ~15MB
  (~12MB of `.debug_*`); stripping brings it to ~2.3MB. The macOS Mach-O
  target does not embed DWARF (it was already ~2.5MB unstripped).
- The release gate runs the native test suite against **both** the system and
  the vendored libcurl, because the two link different libcurl feature sets
  (the vendored one lacks HTTP/2) and the system-only suite used to miss the
  resulting 502-on-bodied-request bug.

## Commands

- `./zig build` — build the `MxProxy` executable.
- `./zig build test` — compile and run all tests (config unit + integration
  tests live in `test/proxy_test.zig`; router/rewrite unit tests in
  `test/router_test.zig`). Both are separate test roots wired to the `test`
  step in `build.zig`.
- `./zig build run -- <args>` — run the proxy with args (e.g. `--port=8080`).

## Layout

- `src/main.zig` — entry: CLI parse, config load, server start, signals.
- `src/config.zig` — config structs + JSON decode + validation (see `Config`).
- `src/router.zig` — path rewrite (plain prefix now; extensible to regex).
- `src/forward.zig` — the proxy core (parse request, drive libcurl directly).
- `src/server.zig` — accept loop, thread-per-connection, shutdown.
- `src/headers.zig` — hop-by-hop filtering + header override application.
- `test/proxy_test.zig` — config unit tests + in-process integration tests.
- `test/router_test.zig` — router/rewrite unit tests (path-rewrite +
  `${N}`/`\$` replacement syntax). Both are separate test roots wired to the
  `test` step in `build.zig`.

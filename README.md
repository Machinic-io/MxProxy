# MxProxy

A fast, lightweight HTTP **reverse proxy** written in [Zig](https://ziglang.org). MxProxy forwards client requests to one or more upstream servers while rewriting paths, manipulating headers, and handling CORS — streaming request and response bodies rather than buffering whole payloads in memory. It is useful for combining multiple microservices into a cohesive environment for development and testing.

[![Build and test](https://github.com/Machinic-io/MxProxy/actions/workflows/ci.yml/badge.svg)](https://github.com/Machinic-io/MxProxy/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.17.0-informational)](https://ziglang.org/)

## Highlights

- **Multi-upstream routing** — prefix or regex path rewriting with first-match-wins, plus a catch-all passthrough for rule-less upstreams.
- **Header control** — set or delete headers in either direction (requests to the upstream, responses to the client).
- **CORS out of the box** — swap `Access-Control-Allow-Origin` for a configured value (per-upstream override → CLI default → `*`), and rewrite `Origin` so the upstream sees a same-origin request.
- **HTTP/1.1 + HTTP/2 upstreams** — per-upstream protocol selection with an `auto` mode that negotiates HTTP/2 over TLS and transparently falls back to HTTP/1.1 when it is safe to do so. The client-facing side is HTTP/1.1 only.
- **Transparent compression** — `Accept-Encoding`/`Content-Encoding` are relayed verbatim (never decoded), so the upstream can compress for the real client.
- **Streaming bodies** — `Content-Length` and chunked request bodies are relayed, and response bodies stream straight from libcurl to the client. The proxy answers `Expect: 100-continue` itself (it sends `100 Continue` before pulling the body) and does not relay the header upstream.
- **TLS** — HTTPS upstreams, with an opt-in `insecure` mode that skips certificate verification.
- **Interface binding** — upstream traffic can be forced out through a specific network interface (e.g. `eth0`) via libcurl's `CURLOPT_INTERFACE`; a per-upstream `interface` falls back to the top-level default.
- **Mature upstream engine** — upstream transfers are driven directly against the system libcurl.

## How it works

`MxProxy` runs an accept loop and spawns a thread per connection. Each request is parsed (HTTP/1.1 request line + headers), resolved to an upstream and a rewritten path, and handed to libcurl. The response head is relayed to the client (hop-by-hop headers stripped, overrides and CORS applied) and the body is streamed as libcurl receives it.

```mermaid
flowchart TD
    A([Client request]) --> B[Accept loop<br/>one thread per connection]
    B --> C[Parse HTTP/1.1 request line + headers]
    C --> RESOLVE
    subgraph RESOLVE ["Resolve upstream + rewrite path — router → pathmap"]
        direction TB
        P1["Iterate upstreams, then their path rules (first match wins)"]
        P1 --> P2{"rule.rewrite matches the client path?"}
        P2 -->|"plain: strict prefix"| P3["splice the client remainder<br/>under the remote prefix"]
        P2 -->|"regex: full match"| P4["render the remote template<br/>with capture-group substitution"]
        P3 --> P5["Route: upstream + rewritten,<br/>normalized upstream path"]
        P4 --> P5
        P2 -->|"no rule matches"| P6{"a rule-less upstream (catch-all) exists?"}
        P6 -->|"yes"| P7["Route: path forwarded unchanged"]
        P6 -->|"no route"| P8["404"]
    end
    P5 --> E[Build request headers<br/>drop hop-by-hop, apply overrides + CORS]
    P7 --> E
    P8 --> Z404([404 sent])
    E --> F{Request body?}
    F -->|none| G[no body]
    F -->|Content-Length| H[streamed, bounded]
    F -->|chunked| I[decoded on the fly, bounded]
    G --> TRANSFER
    H --> TRANSFER
    I --> TRANSFER
    subgraph TRANSFER ["libcurl transfer: http1 / http2 / auto"]
        direction TB
        R1[read callback: supply request body, 0 when bodyless]
        R2[header callback: relay response head<br/>strip hop-by-hop, apply overrides + CORS]
        R3[write callback: stream response body]
        R1 --> R2 --> R3
    end
    TRANSFER --> FB{"auto, failed before any bytes,<br/>body re-sendable?"}
    FB -->|yes: retry HTTP/1.1| TRANSFER
    FB -->|no| Z([Response sent])
```

The pipeline is split across a few focused modules:

| Module | Responsibility |
| --- | --- |
| `src/main.zig` | CLI parsing, config load, startup, signals |
| `src/config.zig` | Config structs, JSON decode + validation |
| `src/router.zig` | Resolve upstream + rewrite path (first match wins, catch-all) |
| `src/pathmap.zig` | Path rules: plain prefix + regex rewrite (the `PathMapping` vtable) |
| `src/headers.zig` | Hop-by-hop filtering, header overrides, CORS |
| `src/forward.zig` | Proxy core: parse request, drive libcurl |
| `src/server.zig` | Accept loop, thread-per-connection, graceful shutdown |

## Why libcurl

Upstream transfers are driven directly against [libcurl](https://curl.se/), the de facto standard C library for URL transfers. A proxy's upstream client is exactly where protocol edge cases hide, and libcurl is one of the most battle-tested HTTP clients in existence.

- **Protocol coverage without the work** — HTTP/1.1, HTTP/2 over TLS (ALPN negotiation), and the transparent HTTP/1.1 fallback behind `auto` mode all come from libcurl. A fully conformant HTTP/2 + TLS client in pure Zig would be a large project and a large attack surface; the Zig stdlib has no client with this coverage.
- **Streaming fits the design** — libcurl's callback model (read/header/write) maps one-to-one onto MxProxy's relay: the request body is supplied on demand, the response head is relayed as soon as it arrives, and the body streams straight through to the client without buffering.
- **System library, not vendored** — the build links against the system libcurl (see [Requirements](#requirements)), so there is no large C dependency tree in the repo; updates and security fixes are handled by the OS/distro.
- **Thin, auditable Zig bindings** — the [zig-curl](https://github.com/jiacai2050/zig-curl) bindings keep the interface small: `src/forward.zig` drives `curl_easy_*` directly with three callbacks.
- **Features for free** — the connect and overall timeout budgets (`connect_timeout_ms`/`timeout_ms`) and TLS with opt-in skip-verification (`insecure`) map straight onto libcurl options.

## Requirements

- **Zig 0.17** — the project pins its toolchain (see [Building](#building)).
- **System libcurl** — e.g. `libcurl4-openssl-dev` on Debian/Ubuntu. The build links against it rather than vendoring.
- **Local dependency checkouts** as siblings of this repo (referenced by `build.zig.zon`):
  - [`zig-curl`](https://github.com/jiacai2050/zig-curl) → `../zig-curl` (libcurl C bindings)
  - [`httpx`](https://github.com/muhammad-fiaz/httpx.zig) → `../httpx.zig` (HTTP/1.1 parser/writer + TCP sockets)
  - [`zig-regex`](https://github.com/zig-utils/zig-regex) → `../zig-regex` (regex path-rewrite rules)

## Building

The repo ships a `./zig` wrapper that pins the build to a Zig 0.17 toolchain, so you do not need a matching `zig` on your `PATH`:

```sh
# Build the MxProxy executable
./zig build

# Run the full test suite (config, router, headers + integration)
./zig build test

# Build and run with arguments
./zig build run -- --port=8080 --upstream-host=https://example.com
```

Prefer to call `zig` directly? Point the wrapper at your 0.17 toolchain:

```sh
ZIG_17=/path/to/zig-0.17 ./zig build
```

## Running

MxProxy is configured by a JSON config file, an inline JSON string, and/or command-line flags. Precedence (lowest → highest):

> **defaults → config file → `--config-json` → command-line flags**

### Quick start

Forward everything to a single upstream:

```sh
./zig-out/bin/MxProxy --upstream-host=https://example.com --port=8080
```

Or from a config file:

```sh
./zig-out/bin/MxProxy --config=config.json
```

### Command-line flags

| Flag | Description |
| --- | --- |
| `--config=<path>` | Path to a JSON config file. |
| `--config-json=<json>` | Inline JSON config (top-level keys only). |
| `--port=<u16>` | Listen port (default `8080`). |
| `--timeout=<ms>` | Default overall upstream timeout in milliseconds (default `900000`). A per-upstream `timeout_ms` still overrides it. |
| `--connect-timeout=<ms>` | Upstream connect timeout in milliseconds (default `10000`). A per-upstream `connect_timeout_ms` still overrides it. |
| `--insecure` | Skip TLS certificate verification for all upstreams. A per-upstream `insecure` still overrides it. |
| `--upstream-host=<scheme://authority>` | Use a single catch-all upstream. Conflicts if the config already defines upstreams. |
| `--access-control-allow-origin=<value>` | Default CORS origin swapped into responses (otherwise `*`). |
| `--interface=<name>` | Default upstream-facing network interface (e.g. `eth0`). |
| `--verbose`, `-v` | Print verbose proxy logs (config dump at startup, per-upstream details, extra per-request diagnostics). |
| `--verbose-upstream` | Enable libcurl verbose logging of upstream transactions (to stderr). |
| `--silent` | Hide info-level log messages. The per-request summary line (printed by default) and other info output are suppressed; warning/error messages still print. |

### Config file

All fields are optional; omitted fields fall back to their defaults.

```json
{
  "port": 8080,
  "interface": "eth0",
  "timeout_ms": 900000,
  "connect_timeout_ms": 10000,
  "insecure": false,
  "upstream": [
    {
      "host": "https://api.example.com",
      "interface": "eth1",
      "timeout_ms": 5000,
      "connect_timeout_ms": 3000,
      "insecure": false,
      "protocol": "auto",
      "request_headers": {
        "X-Forwarded-For": "203.0.113.5",
        "Origin": null
      },
      "response_headers": {
        "Server": null,
        "Access-Control-Allow-Origin": "https://app.example.com"
      },
      "path": [
        { "type": "plain", "local": "/api/", "remote": "/v1/" },
        { "type": "plain", "local": "", "remote": "" }
      ]
    }
  ]
}
```

#### Top-level fields

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `port` | number | `8080` | Port to listen on. |
| `interface` | string | _(none)_ | Default upstream-facing network interface. |
| `timeout_ms` | number | `900000` | Default overall upstream timeout in milliseconds. |
| `connect_timeout_ms` | number | `10000` | Default upstream connect timeout in milliseconds. |
| `insecure` | bool | `false` | Default for skipping TLS certificate verification (see `--insecure`). |
| `upstream` | array | `[]` | Upstream servers, in match order. |

#### Upstream fields

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `host` | string | — | Upstream origin URL: `scheme://authority` (e.g. `https://api.example.com`). **Required.** |
| `interface` | string | inherit | Network interface for this upstream. Falls back to the top-level `interface`. |
| `timeout_ms` | number | inherit | Overall upstream timeout in milliseconds. Falls back to the top-level `timeout_ms` (default `900000`). |
| `connect_timeout_ms` | number | inherit | Upstream connect timeout in milliseconds. Falls back to the top-level `connect_timeout_ms` (default `10000`). |
| `insecure` | bool | inherit | Skip TLS certificate verification. Falls back to the top-level `insecure` (default `false`). |
| `protocol` | string | `"auto"` | `"http1"`, `"http2"`, or `"auto"`. |
| `request_headers` | object | `{}` | Header overrides applied to requests sent upstream. |
| `response_headers` | object | `{}` | Header overrides applied to responses sent to the client. |
| `path` | array | `[]` | Path rewrite rules, first match wins. An empty list makes the upstream a catch-all. |

The overall timeout must be greater than the connect timeout (checked at startup
for the effective values, `ConnectTimeoutNotLessThanOverall`): libcurl caps the
connect phase by the connect timeout and the whole transfer by the overall
timeout, so `overall <= connect` is meaningless.

#### Path rules

Each rule rewrites the client path before forwarding:

```json
{ "type": "plain", "local": "/api/", "remote": "/v1/" }
```

- `type` is `"plain"` (a strict prefix match) or `"regex"` (a full-match pattern rewrite). It defaults to `"plain"` when omitted.
- **`plain`** — `local` is the client-facing prefix to strip (`""` or `"/"` matches any path); `remote` is the upstream prefix to splice in (`""` or `"/"` maps to the upstream root). The client remainder is spliced under `remote` into a clean absolute path.
- **`regex`** — `local` is a regular expression that must match the **entire** client path (a partial match is a non-match); it is compiled once at config load, so a malformed pattern is rejected at startup. `remote` is an upstream template that may reference the match and capture groups — `$0`/`${0}` is the whole match, `$1`/`$2`/… are single-digit groups, and `${1}`/…/`${999}` reference the groups beyond the ninth; `\$` is a literal `$`. A `$` not followed by a digit or `{`, or pointing at a group that does not exist (or outside 0–999), is emitted literally. The rendered template is normalized to a clean absolute path.

```json
{ "type": "regex", "local": "/api/product/([0-9]+)/info", "remote": "/api/product/info/$1" }
```

- The first matching rule wins (upstream order, then rule order). If no rule matches, the first upstream with no `path` rules forwards the path unchanged; if there is none, the request 404s.

#### Header overrides

`request_headers` and `response_headers` map a header name to a value:

- a **string** sets the header to that value;
- **`null`** deletes the header;
- an **absent** name is passed through unchanged.

Two headers get special treatment:

- **`Origin`** (request) is swapped for the upstream's own origin so the upstream sees a same-origin request. A per-upstream `Origin` override wins if present.
- **`Access-Control-Allow-Origin`** (response) is swapped for the configured CORS value: a per-upstream `response_headers` override first, then `--access-control-allow-origin`, then `*`.

### `auto` protocol mode

With `"protocol": "auto"`, MxProxy tries HTTP/2 over TLS first. If the upstream transfer fails **before any bytes reach the client** and the request body is re-sendable, it transparently retries over HTTP/1.1 — the client sees a single response, but the failed first attempt is logged at info level. (A streaming request body that is consumed on the first attempt disables this fallback.)

### Error attribution

When a request fails, MxProxy attributes the fault to the party responsible and answers (and logs) accordingly: client faults get a `4xx`, upstream failures get a `502`, proxy-internal faults get a `500`.

- **Malformed request head → `400`** — a bad request line or header is rejected before anything is forwarded. An oversized head (larger than 64 KiB, or more headers than the parser allows) gets `431` instead. Contradictory body framing — e.g. both `Content-Length` and `Transfer-Encoding` (a request-smuggling vector) — and bad `Content-Length` values are also rejected with `400`.
- **Incomplete or malformed body → `400`** — the client sends fewer bytes than the declared `Content-Length`, or its chunked body is malformed or EOF arrives before the terminating chunk. The transfer is aborted immediately, so a truncated body is never forwarded to the upstream.
- **Premature client close → `400`** — the client disconnects while its body is still being read, or mid-response while the proxy writes back. The failed transfer is attributed to the client, not the upstream; the proxy answers `400` when the upstream's response head has not been relayed yet (once it is in flight, nothing more can be said).
- **Upstream failure → `502`** — the upstream is unreachable, the TLS handshake fails, or the transfer times out. The log carries the libcurl reason and which budget tripped (`connect timeout` vs `overall timeout`).
- **Proxy fault → `500`** — e.g. out of memory building the request, before the upstream transfer starts.

The same attribution applies to the logs: a client fault prints `client error` at info level, an upstream failure prints `upstream error` (info level for routine timeouts, error level otherwise), so a flaky client cannot masquerade as an upstream outage in monitoring.

### Debugging upstream headers

`--verbose` logs MxProxy's own decisions (the computed upstream URL, the per-request summary). To see what actually crosses the wire, use `--verbose-upstream`: it enables libcurl's verbose diagnostics, which print every upstream transaction to stderr — the full request and response headers as exchanged with the upstream, plus connection and protocol state (TCP connect, TLS/ALPN negotiation for HTTPS upstreams). Body bytes are not included.

Against a local test upstream:

```
./zig build run -- --port=8080 --upstream-host=http://127.0.0.1:8081 --verbose-upstream

*   Trying 127.0.0.1:8081...
* Connected to 127.0.0.1 (127.0.0.1) port 8081
> GET / HTTP/1.1
Host: 127.0.0.1:8081
User-Agent: MxProxy
Accept: */*

< HTTP/1.0 200 OK
< Server: SimpleHTTP/0.6 Python/3.12.3
< Content-Type: text/html; charset=utf-8
< Content-Length: 8112
```

- `>` — the request line and headers MxProxy sends upstream: the final form after path rewrite, hop-by-hop stripping, header overrides, and the `Origin`/CORS swaps have been applied. The `Host` header is the upstream's origin, not the client's.
- `<` — the raw response headers from the upstream, before the proxy strips hop-by-hop headers or applies response overrides.
- `*` — connection and protocol details; the version on the `>` line shows what `auto` mode settled on (`HTTP/2` when HTTP/2 over TLS was negotiated).

This is the ground truth for what the upstream actually received and returned: use it to verify header overrides and the `Origin` swap took effect, to check the rewritten path, and to diagnose HTTP/2-vs-HTTP/1.1 selection in `auto` mode.

## Testing

The suite covers config parsing/validation, routing, header handling, and end-to-end relay (an in-process upstream + proxy + client), including a concurrency test:

```sh
./zig build test
```

## Project layout

```
src/main.zig        entry point: CLI, config, signals
src/config.zig      config structs + JSON decode/validation
src/router.zig      resolve upstream + rewrite path (first match wins, catch-all)
src/pathmap.zig     path rules (plain prefix + regex), the PathMapping vtable
src/headers.zig     hop-by-hop filtering + header overrides + CORS
src/forward.zig     proxy core: parse request, drive libcurl
src/server.zig      accept loop + thread-per-connection + shutdown
test/proxy_test.zig unit + integration tests
```

## License

[MIT](./LICENSE) — see [LICENSE](./LICENSE).

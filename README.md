# MxProxy

A fast, lightweight HTTP **reverse proxy** written in [Zig](https://ziglang.org). MxProxy forwards client requests to one or more upstream servers while rewriting paths, manipulating headers, and handling CORS — streaming request and response bodies rather than buffering whole payloads in memory. It is useful for combining multiple microservices into a cohesive environment for development and testing.

[![Build and test](https://github.com/Machinic-io/MxProxy/actions/workflows/ci.yml/badge.svg)](https://github.com/Machinic-io/MxProxy/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.17.0-informational)](https://ziglang.org/)

## Highlights

- **Multi-upstream routing** — strict-prefix path matching with first-match-wins, plus a catch-all passthrough for rule-less upstreams.
- **Header control** — set or delete headers in either direction (requests to the upstream, responses to the client).
- **CORS out of the box** — swap `Access-Control-Allow-Origin` for a configured value (per-upstream override → CLI default → `*`), and rewrite `Origin` so the upstream sees a same-origin request.
- **HTTP/1.1 + HTTP/2** — per-upstream protocol selection with an `auto` mode that negotiates HTTP/2 over TLS and transparently falls back to HTTP/1.1 when it is safe to do so.
- **Transparent compression** — `Accept-Encoding`/`Content-Encoding` are relayed verbatim (never decoded), so the upstream can compress for the real client.
- **Streaming bodies** — `Content-Length` and chunked request bodies are relayed, and response bodies stream straight from libcurl to the client.
- **TLS** — HTTPS upstreams, with an opt-in `insecure` mode that skips certificate verification.
- **Mature upstream engine** — upstream transfers are driven directly against the system libcurl.

## How it works

`MxProxy` runs an accept loop and spawns a thread per connection. Each request is parsed (HTTP/1.1 request line + headers), resolved to an upstream and a rewritten path, and handed to libcurl. The response head is relayed to the client (hop-by-hop headers stripped, overrides and CORS applied) and the body is streamed as libcurl receives it.

The pipeline is split across a few focused modules:

| Module | Responsibility |
| --- | --- |
| `src/main.zig` | CLI parsing, config load, startup, signals |
| `src/config.zig` | Config structs, JSON decode + validation |
| `src/router.zig` | Path matching + rewrite |
| `src/headers.zig` | Hop-by-hop filtering, header overrides, CORS |
| `src/forward.zig` | Proxy core: parse request, drive libcurl |
| `src/server.zig` | Accept loop, thread-per-connection, graceful shutdown |

## Requirements

- **Zig 0.17** — the project pins its toolchain (see [Building](#building)).
- **System libcurl** — e.g. `libcurl4-openssl-dev` on Debian/Ubuntu. The build links against it rather than vendoring.
- **Local dependency checkouts** as siblings of this repo (referenced by `build.zig.zon`):
  - [`zig-curl`](https://github.com/jiacai2050/zig-curl) → `../zig-curl` (libcurl C bindings)
  - [`httpx`](https://github.com/muhammad-fiaz/httpx.zig) → `../httpx.zig` (HTTP/1.1 parser/writer + TCP sockets)

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
| `--timeout=<ms>` | Default upstream request timeout in milliseconds (default `10000`). A per-upstream `timeout_ms` still overrides it. |
| `--insecure` | Skip TLS certificate verification for all upstreams. A per-upstream `insecure` still overrides it. |
| `--upstream-host=<scheme://authority>` | Use a single catch-all upstream. Conflicts if the config already defines upstreams. |
| `--access-control-allow-origin=<value>` | Default CORS origin swapped into responses (otherwise `*`). |
| `--interface=<name>` | Default upstream-facing network interface (e.g. `eth0`). |
| `--verbose`, `-v` | Print per-request proxy logs. |
| `--verbose-upstream` | Enable libcurl verbose logging of upstream transactions (to stderr). |

### Config file

All fields are optional; omitted fields fall back to their defaults.

```json
{
  "port": 8080,
  "interface": "eth0",
  "timeout_ms": 10000,
  "insecure": false,
  "upstream": [
    {
      "host": "https://api.example.com",
      "interface": "eth1",
      "timeout_ms": 5000,
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
| `timeout_ms` | number | `10000` | Default upstream request timeout in milliseconds. |
| `insecure` | bool | `false` | Default for skipping TLS certificate verification (see `--insecure`). |
| `upstream` | array | `[]` | Upstream servers, in match order. |

#### Upstream fields

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `host` | string | — | Upstream origin URL: `scheme://authority` (e.g. `https://api.example.com`). **Required.** |
| `interface` | string | inherit | Network interface for this upstream. Falls back to the top-level `interface`. |
| `timeout_ms` | number | inherit | Upstream request timeout in milliseconds. Falls back to the top-level `timeout_ms` (default `10000`). |
| `insecure` | bool | inherit | Skip TLS certificate verification. Falls back to the top-level `insecure` (default `false`). |
| `protocol` | string | `"auto"` | `"http1"`, `"http2"`, or `"auto"`. |
| `request_headers` | object | `{}` | Header overrides applied to requests sent upstream. |
| `response_headers` | object | `{}` | Header overrides applied to responses sent to the client. |
| `path` | array | `[]` | Path rewrite rules, first match wins. An empty list makes the upstream a catch-all. |

#### Path rules

Each rule rewrites the client path before forwarding:

```json
{ "type": "plain", "local": "/api/", "remote": "/v1/" }
```

- `type` is `"plain"` (a strict prefix match) — the only supported type today.
- `local` is the client-facing prefix to strip. `""` or `"/"` matches any path.
- `remote` is the upstream prefix to splice in. `""` or `"/"` maps to the upstream root.
- The first matching rule wins (upstream order, then rule order). If no rule matches, the first upstream with no `path` rules forwards the path unchanged.

#### Header overrides

`request_headers` and `response_headers` map a header name to a value:

- a **string** sets the header to that value;
- **`null`** deletes the header;
- an **absent** name is passed through unchanged.

Two headers get special treatment:

- **`Origin`** (request) is swapped for the upstream's own origin so the upstream sees a same-origin request. A per-upstream `Origin` override wins if present.
- **`Access-Control-Allow-Origin`** (response) is swapped for the configured CORS value: a per-upstream `response_headers` override first, then `--access-control-allow-origin`, then `*`.

### `auto` protocol mode

With `"protocol": "auto"`, MxProxy tries HTTP/2 over TLS first. If the upstream transfer fails **before any bytes reach the client** and the request body is re-sendable, it transparently retries over HTTP/1.1. (A streaming request body that is consumed on the first attempt disables this fallback.)

## Testing

The suite covers config parsing/validation, routing, header handling, and end-to-end relay (an in-process upstream + proxy + client), including a concurrency test:

```sh
./zig build test
```

## Project layout

```
src/main.zig        entry point: CLI, config, signals
src/config.zig      config structs + JSON decode/validation
src/router.zig      path matching + rewrite
src/headers.zig     hop-by-hop filtering + header overrides + CORS
src/forward.zig     proxy core: parse request, drive libcurl
src/server.zig      accept loop + thread-per-connection + shutdown
test/proxy_test.zig unit + integration tests
```

## License

[MIT](./LICENSE) — see [LICENSE](./LICENSE).

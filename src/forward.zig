const std = @import("std");
const curl = @import("curl");
const httpx = @import("httpx");
const tcp = httpx.tcp;
const parser = httpx.http1.parser;
const config_mod = @import("config");
const router_mod = @import("router");
const headers_mod = @import("headers");

const log = std.log.scoped(.forward);

/// Which timeout budget a failed upstream transfer tripped. libcurl reports
/// both a connect timeout and an overall timeout as CURLE_OPERATION_TIMEDOUT,
/// so the kind is inferred from the elapsed total time (see classifyTimeout).
pub const TimeoutKind = enum {
    /// The TCP/TLS connect phase exceeded the connect timeout.
    connect,
    /// The whole transfer exceeded the overall timeout.
    overall,
};

/// Classify which timeout budget a CURLE_OPERATION_TIMEDOUT transfer tripped,
/// from the elapsed total time. A connect timeout ends at ~connect_ms and an
/// overall timeout at ~overall_ms; overall > connect (enforced by config
/// validation), so the midpoint between the two budgets separates the cases.
pub fn classifyTimeout(elapsed_ms: u64, connect_ms: u64, overall_ms: u64) TimeoutKind {
    return if (elapsed_ms <= (connect_ms + overall_ms) / 2) .connect else .overall;
}

/// The HTTP status for a request-head/framing parse failure: oversized heads
/// are 431, an out-of-memory is a proxy fault (500), everything else is a
/// client error (400).
fn headParseErrorStatus(err: parser.ParseError) u16 {
    return switch (err) {
        parser.ParseError.HeaderTooLarge, parser.ParseError.TooManyHeaders => 431,
        parser.ParseError.OutOfMemory => 500,
        else => 400,
    };
}

/// True when the client sent `Expect: 100-continue` (case-insensitive).
fn wants100Continue(fields: []const parser.Field) bool {
    for (fields) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, "Expect") and std.ascii.findIgnoreCase(f.value, "100-continue") != null) return true;
    }
    return false;
}

const Self = @This();

config: *const config_mod.Config,
router: router_mod.Router,
verbose: bool,
/// The --silent flag. When true, info-level log messages are suppressed
/// process-wide (see the log function in main.zig), and the per-request line
/// in forward() is skipped.
silent: bool,

pub const Forwarder = Self;

pub fn init(config: *const config_mod.Config, verbose: bool, silent: bool) !Self {
    return .{
        .config = config,
        .router = router_mod.Router.init(config.upstream),
        .verbose = verbose,
        .silent = silent,
    };
}

/// Handle one client connection. Runs on its own thread; the caller owns and
/// closes the socket. Errors are logged (or swallowed for benign close).
pub fn handle(self: *Self, allocator: std.mem.Allocator, socket: *tcp.Socket) void {
    self.forward(allocator, socket) catch |err| {
        switch (err) {
            // Benign close, and upstream errors already reported by forward().
            error.ClientClosed, error.Curl => {},
            // A mid-request OOM is not benign: log it so it is diagnosable.
            error.OutOfMemory => log.err("request: out of memory", .{}),
            else => log.err("request error: {any}", .{err}),
        }
    };
}

const BodyMode = enum { none, socket, chunked };

/// Bounded, streaming decode of a chunked request body. Raw bytes are read from
/// the socket in bounded chunks, decoded in place, and the decoded payload is
/// handed to libcurl on demand. Memory is bounded to `work_cap` + `decoded_cap`
/// regardless of the (unbounded) body size: the client's chunked framing is
/// decoded and re-emitted, so the upstream sees a chunked (HTTP/1.1) / unframed
/// (HTTP/2) upload rather than a Content-Length one.
const ChunkedStream = struct {
    socket: *const tcp.Socket,
    allocator: std.mem.Allocator,
    decoder: parser.ChunkedDecoder,
    work: []u8, // raw bytes read from the socket (capacity work_cap).
    work_len: usize,
    decoded: []u8, // decoded payload not yet served, kept at the front.
    dec_len: usize,
    done: bool, // terminating chunk reached.

    const work_cap = 64 * 1024;
    const decoded_cap = 128 * 1024;

    fn init(allocator: std.mem.Allocator, socket: *const tcp.Socket, seed: []const u8) !*ChunkedStream {
        const cs = try allocator.create(ChunkedStream);
        errdefer allocator.destroy(cs);
        cs.allocator = allocator;
        cs.socket = socket;
        cs.decoder = parser.ChunkedDecoder.init();
        cs.work = try allocator.alloc(u8, work_cap);
        errdefer allocator.free(cs.work);
        cs.decoded = try allocator.alloc(u8, decoded_cap);
        errdefer allocator.free(cs.decoded);
        cs.dec_len = 0;
        cs.done = false;
        if (seed.len > 0) {
            // `seed` is the tail (body bytes read with the head), <= 64 KiB.
            if (seed.len > work_cap) return error.Bug;
            @memcpy(cs.work[0..seed.len], seed);
            cs.work_len = seed.len;
        } else {
            cs.work_len = 0;
        }
        return cs;
    }

    fn deinit(self: *ChunkedStream) void {
        self.allocator.free(self.work);
        self.allocator.free(self.decoded);
        self.allocator.destroy(self);
    }

    /// Read up to `out.len` decoded bytes into `out`, reading from the socket
    /// and decoding as needed. Returns 0 on EOF (terminating chunk reached and
    /// all payload served).
    fn read(self: *ChunkedStream, out: []u8) !usize {
        while (!self.done and self.dec_len < out.len and self.dec_len + work_cap <= self.decoded.len) {
            try self.decodeMore();
        }
        const want = @min(self.dec_len, out.len);
        if (want == 0) return 0;
        @memcpy(out[0..want], self.decoded[0..want]);
        const keep = self.dec_len - want;
        if (keep > 0) std.mem.copyForwards(u8, self.decoded[0..keep], self.decoded[want..self.dec_len]);
        self.dec_len = keep;
        return want;
    }

    /// Decode the buffered raw bytes, append the decoded payload to `decoded`,
    /// compact the raw remainder, and read more raw so the next call progresses.
    fn decodeMore(self: *ChunkedStream) !void {
        const res = self.decoder.decode(self.work[0..self.work_len]);
        if (res) |_| {
            self.done = true; // terminating chunk reached.
        } else |err| {
            if (err != parser.ParseError.Incomplete) return error.BadRequest; // malformed
            // Incomplete: keep reading; not done yet.
        }
        const decoded_len = self.decoder.decodedLen;
        const consumed = self.decoder.rawConsumed;
        if (decoded_len > 0) {
            @memcpy(self.decoded[self.dec_len..][0..decoded_len], self.work[0..decoded_len]);
            self.dec_len += decoded_len;
        }
        const keep = self.work_len - consumed;
        if (keep > 0) std.mem.copyForwards(u8, self.work[0..keep], self.work[consumed..self.work_len]);
        self.work_len = keep;
        if (self.done) return;
        const n = self.socket.read(self.work[self.work_len..]) catch return error.ClientClosed;
        if (n == 0) return error.ChunkedBodyIncomplete; // EOF before terminating chunk
        self.work_len += n;
    }
};

/// A client-side fault detected while streaming the request body (or writing
/// the response back). When set on the Ctx, a failed transfer is the client's
/// fault: forward() answers 400 and blames the client in the log, not the
/// upstream.
const ClientFault = error{
    /// The client closed the connection (or its write half) early.
    ClientClosed,
    /// The client sent fewer bytes than the declared Content-Length.
    ShortBody,
    /// The client's chunked body is malformed or lacks its terminator.
    MalformedChunked,
};

/// Per-connection state shared with the three libcurl callbacks. `tail` and
/// `chunked_stream` are owned here (freed in deinit); `socket`/
/// `response_overrides` borrow from the caller.
const Ctx = struct {
    socket: *const tcp.Socket,
    allocator: std.mem.Allocator,
    body_mode: BodyMode,
    tail: []const u8,
    tail_pos: usize,
    body_remaining: usize,
    chunked_stream: ?*ChunkedStream,
    /// A client-side fault that failed the transfer (see ClientFault). When
    /// set, forward() answers 400 and blames the client in the log.
    client_fault: ?ClientFault = null,
    head_buf: std.array_list.Managed(u8),
    head_done: bool,
    response_status: u16,
    response_overrides: *const headers_mod.OverrideMap,
    /// Default value swapped into Access-Control-Allow-Origin when the upstream
    /// sent that header and no per-upstream override applies (see headers.zig).
    default_origin: ?[]const u8,
    /// libcurl error message from the last failed transfer, if any. Points at
    /// libcurl's static error string (from `curl_easy_strerror`), so it is not
    /// owned and needs no freeing. Lets the request error be logged with the
    /// actual upstream failure reason.
    curl_error: ?[]const u8 = null,
    /// Which timeout budget the last failed transfer tripped (heuristic; see
    /// classifyTimeout). `null` when the last failure was not a timeout.
    timeout_kind: ?TimeoutKind = null,
    /// Elapsed total transfer time in ms when a timeout fired (see timeout_kind).
    timeout_elapsed_ms: ?u64 = null,

    fn deinit(self: *Ctx) void {
        if (self.tail.len > 0) self.allocator.free(self.tail);
        if (self.chunked_stream) |cs| cs.deinit();
        self.head_buf.deinit();
    }

    /// Feed the next chunk of the request body to libcurl. Returning 0 signals
    /// EOF to the (upload) transfer.
    fn readBody(self: *Ctx, out: []u8) !usize {
        switch (self.body_mode) {
            .none => return 0,
            .socket => {
                // Serve the already-read tail first, then pull from the socket,
                // capped at the declared Content-Length.
                if (self.tail_pos < self.tail.len) {
                    const avail = self.tail.len - self.tail_pos;
                    const want = @min(avail, out.len);
                    if (want == 0) return 0;
                    @memcpy(out[0..want], self.tail[self.tail_pos..][0..want]);
                    self.tail_pos += want;
                    self.body_remaining -= want;
                    return want;
                }
                if (self.body_remaining == 0) return 0;
                const want = @min(self.body_remaining, out.len);
                const n = self.socket.read(out[0..want]) catch {
                    // The client went away mid-body: abort the upload and let
                    // forward() report the fault (400).
                    self.client_fault = ClientFault.ClientClosed;
                    return 0;
                };
                if (n == 0) {
                    // EOF before the declared Content-Length bytes arrived:
                    // the body is shorter than declared (client violation).
                    self.client_fault = ClientFault.ShortBody;
                    return 0;
                }
                self.body_remaining -= n;
                return n;
            },
            .chunked => {
                const cs = self.chunked_stream orelse return error.Bug;
                return cs.read(out) catch |err| switch (err) {
                    error.ChunkedBodyIncomplete, error.BadRequest => {
                        self.client_fault = ClientFault.MalformedChunked;
                        return 0;
                    },
                    error.ClientClosed => {
                        self.client_fault = ClientFault.ClientClosed;
                        return 0;
                    },
                };
            },
        }
    }
};

fn forward(self: *Self, allocator: std.mem.Allocator, socket: *tcp.Socket) !void {
    // 1. Read and parse the request head + headers.
    var head_buf: [65536]u8 = undefined;
    var total: usize = 0;
    var head_res: parser.HeadResult = undefined;
    var fields: [parser.DEFAULT_MAX_HEADERS]parser.Field = undefined;
    var blk: parser.HeaderBlockResult = undefined;
    read_head: while (true) {
        if (total == head_buf.len) {
            // The head is larger than the fixed read buffer. Reject it rather
            // than reading an empty buffer and misreporting it as a close.
            try writeError(socket, allocator, 431);
            log.info("[proxy] request head too large (>64 KiB) -> 431", .{});
            return;
        }
        const n = socket.read(head_buf[total..]) catch return error.ClientClosed;
        if (n == 0) return error.ClientClosed;
        total += n;
        const buf = head_buf[0..total];
        head_res = parser.parseRequestHead(buf, .{}) catch |err| switch (err) {
            parser.ParseError.Incomplete => continue,
            else => {
                const status = headParseErrorStatus(err);
                try writeError(socket, allocator, status);
                log.info("[proxy] malformed request head ({any}) -> {d}", .{ err, status });
                return;
            },
        };
        blk = parser.parseHeaderBlock(buf, head_res.headEnd, &fields, .{}) catch |err| switch (err) {
            parser.ParseError.Incomplete => continue,
            else => {
                const status = headParseErrorStatus(err);
                try writeError(socket, allocator, status);
                log.info("[proxy] malformed request head ({any}) -> {d}", .{ err, status });
                return;
            },
        };
        break :read_head;
    }
    const field_slice = fields[0..blk.count];
    const method = head_res.method;
    const path = head_res.path;
    const start = std.Io.Timestamp.now(socket.io, .awake);

    // 2. Route to an upstream (path rewrite).
    var route = try self.router.resolve(allocator, path) orelse {
        try writeError(socket, allocator, 404);
        log.info("[proxy] {s:<7} {s} -> 404 ({d}us)", .{ method, path, elapsedUs(start, socket.io) });
        return;
    };
    defer route.deinit();
    const upstream = route.upstream;

    // 3. Build the upstream URL (host ++ rewritten, normalized path).
    const remote_path = route.remote_path;
    const url = try allocator.print("{s}{s}", .{ upstream.host, remote_path });
    defer allocator.free(url);
    const url_z = try allocator.printSentinel("{s}", .{url}, 0);
    defer allocator.free(url_z);
    if (self.verbose) log.info("[proxy] {s:<7} {s} -> {s}", .{ method, path, url });

    // 4. Decide body framing from headers, never from the method: GET/DELETE/
    //    HEAD may carry a body too.
    const framing = parser.decideFraming(field_slice, false, 0, method.len) catch |err| {
        // CL/TE smuggling defenses and bad Content-Length values: the client
        // sent contradictory framing -> 400.
        const status = headParseErrorStatus(err);
        try writeError(socket, allocator, status);
        log.info("[proxy] bad request framing ({any}) -> {d}", .{ err, status });
        return;
    };

    // 4b. If the client asked for 100-continue (and the request carries a
    //     body), grant it before pulling the body. Expect is never relayed to
    //     the upstream (see headers.zig), so the upstream never sends its own
    //     100 — this is the only interim the client will see.
    if (framing.framing != .none and wants100Continue(field_slice)) {
        socket.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch return error.ClientClosed;
        if (self.verbose) log.info("[proxy] sent 100 Continue to client ({s} {s})", .{ method, path });
    }

    // 5. Seed context with any body bytes already read alongside the head.
    const tail_start = blk.end;
    var ctx: Ctx = .{
        .socket = socket,
        .allocator = allocator,
        .body_mode = .none,
        .tail = &.{},
        .tail_pos = 0,
        .body_remaining = 0,
        .chunked_stream = null,
        .head_buf = std.array_list.Managed(u8).init(allocator),
        .head_done = false,
        .response_status = 0,
        .response_overrides = &upstream.response_headers.map,
        .default_origin = self.config.default_origin,
    };
    // defer (not errdefer): the happy path falls off the end of forward()
    // without returning an error, so errdefer would skip this and leak
    // tail/body_buffer/head_buf on every successful request.
    defer ctx.deinit();

    if (tail_start < total) {
        const tail_bytes = try allocator.alloc(u8, total - tail_start);
        @memcpy(tail_bytes, head_buf[tail_start..total]);
        ctx.tail = tail_bytes;
    }

    switch (framing.framing) {
        .none => ctx.body_mode = .none,
        .contentLength => {
            if (framing.length == 0) {
                ctx.body_mode = .none;
                if (ctx.tail.len > 0) {
                    allocator.free(ctx.tail);
                    ctx.tail = &.{};
                }
            } else {
                ctx.body_mode = .socket;
                ctx.body_remaining = framing.length;
            }
        },
        .chunked => {
            // Stream+decode the chunked body in bounded chunks (no total
            // buffering). The tail seeds the decoder; the rest is pulled from
            // the socket on demand via the read callback.
            ctx.body_mode = .chunked;
            ctx.chunked_stream = try ChunkedStream.init(allocator, socket, ctx.tail);
            if (ctx.tail.len > 0) {
                allocator.free(ctx.tail);
                ctx.tail = &.{};
            }
        },
        .tunnel => return error.Unsupported,
    }

    // 6. Build the relayed request headers (host/ua + hop-by-hop dropped,
    //    overrides applied, Origin swapped).
    const req_headers = try headers_mod.buildRequestHeaders(allocator, field_slice, &upstream.request_headers.map, upstream.origin());
    defer {
        for (req_headers) |s| allocator.free(s);
        allocator.free(req_headers);
    }

    // 7. Run the transfer, with an HTTP/1.1 fallback for "auto". The request
    //    body is pulled via the read callback, the response head pushed via the
    //    header callback, and the body streamed via the write callback.
    const method_z = try allocator.printSentinel("{s}", .{method}, 0);
    defer allocator.free(method_z);
    // "auto" may fall back to HTTP/1.1, but only when the request body is
    // re-sendable. Both .socket and .chunked consume the client socket on the
    // first pass, so only a bodyless request can be retried.
    const can_fallback = std.mem.eql(u8, upstream.protocol, "auto") and ctx.body_mode == .none;
    var use_fallback: bool = false;
    while (true) {
        const http_version: curl.Easy.HttpVersion = if (use_fallback)
            .http1_1
        else
            firstProtocol(upstream.protocol);
        self.attempt(allocator, &ctx, url_z, upstream, req_headers, method_z, http_version) catch |err| {
            if (can_fallback and !ctx.head_done and !use_fallback and ctx.client_fault == null) {
                // Nothing reached the client; retry the same request over
                // HTTP/1.1. Log the failed attempt first: resetForRetry clears
                // the libcurl reason, so it would otherwise be swallowed.
                if (ctx.timeout_kind) |kind| {
                    const tag = switch (kind) {
                        .connect => "connect timeout",
                        .overall => "overall timeout",
                    };
                    log.info("upstream error: {s} {s} -> {s} ({s} after {d}ms; retrying over HTTP/1.1)", .{ method, path, url, tag, ctx.timeout_elapsed_ms.? });
                } else {
                    log.info("upstream error: {s} {s} -> {s} ({s}; retrying over HTTP/1.1)", .{ method, path, url, ctx.curl_error orelse "unknown libcurl error" });
                }
                resetForRetry(&ctx);
                use_fallback = true;
                continue;
            }
            if (ctx.client_fault) |fault| {
                // A client-side framing fault (premature close, short or
                // malformed body, client gone mid-response): the request is
                // the client's fault -> 400, and the log blames the client, not
                // the upstream.
                log.info("client error: {s} {s} -> {s} ({any})", .{ method, path, url, fault });
                if (!ctx.head_done) try writeError(socket, allocator, 400);
                return;
            }
            if (err == error.Curl) {
                // Report the upstream failure with the libcurl reason so the log
                // says which upstream failed and why. A timeout is tagged with
                // which budget tripped (connect vs overall; see classifyTimeout).
                if (ctx.timeout_kind) |kind| {
                    const tag = switch (kind) {
                        .connect => "connect timeout",
                        .overall => "overall timeout",
                    };
                    // Log at info (not warn): a per-request upstream timeout is a
                    // routine event (the client already gets a 502), and warn would
                    // make the timeout test's expected log a test failure — flakily
                    // attributed to a randomly-adjacent test from the handler thread.
                    log.info("upstream error: {s} {s} -> {s} ({s} after {d}ms)", .{ method, path, url, tag, ctx.timeout_elapsed_ms.? });
                } else {
                    log.err("upstream error: {s} {s} -> {s} ({s})", .{ method, path, url, ctx.curl_error orelse "unknown libcurl error" });
                }
                if (!ctx.head_done) try writeError(socket, allocator, 502);
                return error.Curl;
            }
            // attempt() itself failed before the transfer (e.g. OOM building
            // the request): a proxy fault, not the upstream's.
            if (!ctx.head_done) try writeError(socket, allocator, if (err == error.OutOfMemory) 500 else 502);
            return err;
        };
        break;
    }
    // Printed unless --silent: the routine per-request summary line.
    if (!self.silent) log.info("{s:<4} {s:<32} -> {s:<32} {d} ({d}us)", .{ method, path, remote_path, ctx.response_status, elapsedUs(start, socket.io) });
}

/// Configure a fresh easy handle and run one transfer attempt at `http_version`.
/// The response head (when received) is written to the client by the header
/// callback; the caller inspects `ctx.head_done` to decide whether a retry is
/// safe. The libcurl error (if any) is logged here, where the handle is live.
fn attempt(
    self: *Self,
    allocator: std.mem.Allocator,
    ctx: *Ctx,
    url_z: [:0]const u8,
    upstream: *const config_mod.Upstream,
    req_headers: []const [:0]const u8,
    method_z: [:0]const u8,
    http_version: curl.Easy.HttpVersion,
) !void {
    // Drive libcurl's C API directly. The zig-curl `Easy` wrapper hides its raw
    // handle (no cHandle/diagnosticsRef) and offers no header-function setter,
    // but this proxy needs CURLOPT_HEADERFUNCTION (to relay/rewrite the response
    // head), CURLOPT_READFUNCTION (streaming request body), an arbitrary
    // CURLOPT_CUSTOMREQUEST method, and CURLOPT_INTERFACE. The raw bindings are
    // still exposed via `curl.libcurl`, so we use them directly.
    const curl_handle = curl.libcurl.curl_easy_init() orelse return error.Curl;
    defer curl.libcurl.curl_easy_cleanup(curl_handle);
    var diag: curl.Diagnostics = .{};
    try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_URL, url_z.ptr), &diag);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_HTTP_VERSION, @backingInt(http_version)), &diag);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_FOLLOWLOCATION, @as(c_long, 0)), &diag);
    if (self.config.verbose_upstream) {
        try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_VERBOSE, @as(c_long, 1)), &diag);
    }
    try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_CONNECTTIMEOUT_MS, upstream.effectiveConnectTimeoutMs(self.config.connect_timeout_ms)), &diag);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_TIMEOUT_MS, upstream.effectiveTimeoutMs(self.config.timeout_ms)), &diag);
    const user_agent = [_]u8{ 'M', 'x', 'P', 'r', 'o', 'x', 'y', 0 };
    try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_USERAGENT, &user_agent[0]), &diag);
    // We deliberately do NOT set CURLOPT_ACCEPT_ENCODING. Setting it to ANY
    // value (even "identity") turns on libcurl's automatic content decoding,
    // which decompresses the body out from under the Content-Encoding header.
    // Leaving it unset keeps the relayed body byte-for-byte what upstream sent.
    if (upstream.effectiveInsecure(self.config.insecure)) {
        try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_SSL_VERIFYPEER, @as(c_long, 0)), &diag);
        try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_SSL_VERIFYHOST, @as(c_long, 0)), &diag);
    }
    try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_CUSTOMREQUEST, method_z.ptr), &diag);
    if (upstream.effectiveInterface(self.config.interface)) |iface| {
        const iface_z = try allocator.printSentinel("{s}", .{iface}, 0);
        defer allocator.free(iface_z);
        try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_INTERFACE, iface_z.ptr), &diag);
    }
    var slist: ?*curl.libcurl.struct_curl_slist = null;
    defer if (slist) |s| curl.libcurl.curl_slist_free_all(s);
    for (req_headers) |h| {
        slist = curl.libcurl.curl_slist_append(slist, h.ptr) orelse return error.Curl;
    }
    if (slist) |s| try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_HTTPHEADER, s), &diag);
    if (ctx.body_mode != .none) {
        try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_UPLOAD, @as(c_long, 1)), &diag);
        // A .socket body has a known size (declared Content-Length); a .chunked
        // body does not, so we omit INFILESIZE and let libcurl re-frame the
        // upload as chunked (HTTP/1.1) / unframed (HTTP/2).
        if (ctx.body_mode == .socket) {
            try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_INFILESIZE_LARGE, @as(c_long, @intCast(ctx.body_remaining))), &diag);
        }
        try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_READFUNCTION, readCallback), &diag);
        try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_READDATA, ctx), &diag);
    }
    try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_WRITEFUNCTION, writeCallback), &diag);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_WRITEDATA, ctx), &diag);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_HEADERFUNCTION, headerCallback), &diag);
    try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_HEADERDATA, ctx), &diag);
    curl.checkCode(curl.libcurl.curl_easy_perform(curl_handle), &diag) catch |err| {
        // Remember the libcurl reason so forward() can log an actionable error.
        ctx.curl_error = diag.getMessage();
        // libcurl reports both a connect timeout and an overall timeout as
        // CURLE_OPERATION_TIMEDOUT; infer which one fired from the elapsed total
        // time (a connect timeout ends at ~connect_ms, an overall one at the
        // larger ~timeout_ms budget).
        const timeout_code: curl.libcurl.CURLcode = @intCast(curl.libcurl.CURLE_OPERATION_TIMEDOUT);
        const is_timeout = if (diag.error_code) |ec| switch (ec) {
            .code => |code| code == timeout_code,
            else => false,
        } else false;
        if (is_timeout) {
            var total_time: f64 = 0; // seconds
            _ = curl.libcurl.curl_easy_getinfo(curl_handle, curl.libcurl.CURLINFO_TOTAL_TIME, &total_time);
            const elapsed_ms = @as(u64, @intFromFloat(total_time * 1000.0));
            ctx.timeout_kind = classifyTimeout(elapsed_ms, upstream.effectiveConnectTimeoutMs(self.config.connect_timeout_ms), upstream.effectiveTimeoutMs(self.config.timeout_ms));
            ctx.timeout_elapsed_ms = elapsed_ms;
        }
        return err;
    };
}

/// The first protocol to try for an upstream's `protocol` setting.
fn firstProtocol(protocol: []const u8) curl.Easy.HttpVersion {
    if (std.mem.eql(u8, protocol, "http1")) return .http1_1;
    if (std.mem.eql(u8, protocol, "http2")) return .http2;
    return .http2_tls; // "auto" (default): HTTP/2 over TLS, HTTP/1.1 cleartext.
}

/// Reset the per-attempt state so an HTTP/1.1 fallback re-runs the transfer
/// with a clean slate. Only called for a re-sendable (bodyless) request, so
/// there is no body state to rewind.
fn resetForRetry(ctx: *Ctx) void {
    ctx.head_done = false;
    ctx.response_status = 0;
    ctx.curl_error = null;
    ctx.timeout_kind = null;
    ctx.timeout_elapsed_ms = null;
    ctx.client_fault = null;
    ctx.head_buf.clearRetainingCapacity();
    ctx.tail_pos = 0;
}

/// Microseconds elapsed between `start` and now, read from the same clock.
fn elapsedUs(start: std.Io.Timestamp, io: std.Io) i64 {
    const ns = start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    return @intCast(@divTrunc(ns, 1000));
}

fn readCallback(buffer: ?*anyopaque, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
    const ud = user_data orelse return curl.libcurl.CURL_READFUNC_ABORT;
    const buf = buffer orelse return curl.libcurl.CURL_READFUNC_ABORT;
    const ctx: *Ctx = @ptrCast(@alignCast(ud));
    const max_len = size * nmemb;
    const ptr: [*]u8 = @ptrCast(buf);
    const out: []u8 = ptr[0..max_len];
    const n = ctx.readBody(out) catch return curl.libcurl.CURL_READFUNC_ABORT;
    if (ctx.client_fault != null) {
        // A client-side fault (short or malformed body, premature close).
        // Abort the transfer NOW instead of returning 0: libcurl treats a 0
        // as "upload done" and would silently forward the truncated body and
        // wait for the response, leaving a half-sent request hanging upstream.
        return curl.libcurl.CURL_READFUNC_ABORT;
    }
    return n;
}

fn writeCallback(buffer: ?*anyopaque, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
    const ud = user_data orelse return 0;
    const buf = buffer orelse return 0;
    const ctx: *Ctx = @ptrCast(@alignCast(ud));
    const n = size * nmemb;
    const ptr: [*]const u8 = @ptrCast(buf);
    const data: []const u8 = ptr[0..n];
    ctx.socket.writeAll(data) catch {
        // The client went away mid-response: abort the transfer and attribute
        // the failure to the client, not the upstream.
        ctx.client_fault = ClientFault.ClientClosed;
        return 0;
    };
    return n;
}

/// Maximum bytes of response head (status line + headers) buffered before the
/// terminating blank line. A head larger than this aborts the transfer (502).
const MAX_RESPONSE_HEAD_BYTES = 64 * 1024;

fn headerCallback(buffer: ?*anyopaque, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
    const ud = user_data orelse return 0;
    const buf = buffer orelse return 0;
    const ctx: *Ctx = @ptrCast(@alignCast(ud));
    const n = size * nmemb;
    const ptr: [*]const u8 = @ptrCast(buf);
    const data: []const u8 = ptr[0..n];
    if (ctx.head_done) return n; // ignore trailer bytes
    // Bound the head: an upstream that streams headers without a terminating
    // blank line must not grow this buffer without limit (thread-per-connection
    // would amplify it).
    if (ctx.head_buf.items.len + n > MAX_RESPONSE_HEAD_BYTES) return 0;
    ctx.head_buf.appendSlice(data) catch return 0;
    if (std.mem.indexOf(u8, ctx.head_buf.items, "\r\n\r\n")) |blank| {
        const raw_head = ctx.head_buf.items[0 .. blank + 4];
        // libcurl synthesizes an "HTTP/2 <code>" status line for HTTP/2
        // responses, which the HTTP/1 parser rejects; rewrite it to "HTTP/1.1"
        // so it parses and we relay a well-formed head to the HTTP/1.1 client.
        var head_bytes = raw_head;
        var http2_head: ?[]u8 = null;
        if (std.mem.startsWith(u8, raw_head, "HTTP/2")) {
            http2_head = fixHttp2Head(ctx.allocator, raw_head) catch return 0;
            head_bytes = http2_head.?;
        }
        const head_res = parser.parseResponseHead(head_bytes, .{}) catch {
            if (http2_head) |s| ctx.allocator.free(s);
            return 0;
        };
        if (head_res.statusCode < 200) {
            // A 1xx interim response (100 Continue, 103 Early Hints, ...) is
            // NOT the final response: libcurl passes 1xx blocks to this
            // callback, and relaying one as the final head would break the
            // client. Drop this head block and keep accumulating for the
            // real one.
            defer if (http2_head) |s| ctx.allocator.free(s);
            const keep_from = blank + 4;
            const keep_len = ctx.head_buf.items.len - keep_from;
            if (keep_len > 0) std.mem.copyForwards(u8, ctx.head_buf.items[0..keep_len], ctx.head_buf.items[keep_from..]);
            ctx.head_buf.items = ctx.head_buf.items[0..keep_len];
            return n;
        }
        ctx.response_status = head_res.statusCode;
        const status_line = head_bytes[0 .. head_res.headEnd - 2];
        var fields: [parser.DEFAULT_MAX_HEADERS]parser.Field = undefined;
        const blk = parser.parseHeaderBlock(head_bytes, head_res.headEnd, &fields, .{}) catch {
            if (http2_head) |s| ctx.allocator.free(s);
            return 0;
        };
        const resp_head = headers_mod.buildResponseHead(ctx.allocator, status_line, fields[0..blk.count], ctx.response_overrides, ctx.default_origin) catch {
            if (http2_head) |s| ctx.allocator.free(s);
            return 0;
        };
        defer {
            if (http2_head) |s| ctx.allocator.free(s);
            ctx.allocator.free(resp_head);
        }
        ctx.socket.writeAll(resp_head) catch {
            // The client went away while the response head was being relayed:
            // same attribution as a mid-body close (see writeCallback).
            ctx.client_fault = ClientFault.ClientClosed;
            return 0;
        };
        ctx.head_done = true;
    }
    return n;
}

/// Rewrite an "HTTP/2 <code>" status line (as libcurl synthesizes for HTTP/2
/// responses) to "HTTP/1.1 <code>". Returns an owned slice; the caller frees it.
fn fixHttp2Head(allocator: std.mem.Allocator, head: []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("HTTP/1.1");
    try buf.appendSlice(head[6..]); // drop "HTTP/2", keep " <code> ..."
    return buf.toOwnedSlice();
}

fn writeError(socket: *const tcp.Socket, allocator: std.mem.Allocator, code: u16) !void {
    const reason_phrase = switch (code) {
        400 => "Bad Request",
        404 => "Not Found",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        else => "Error",
    };
    var buf = std.array_list.Managed(u8).init(allocator);
    // defer (not errdefer): the success path writes the body and returns void,
    // so errdefer would skip this and leak buf on every error response.
    defer buf.deinit();
    const sl = try allocator.print("HTTP/1.1 {d} {s}\r\n", .{ code, reason_phrase });
    defer allocator.free(sl);
    try buf.appendSlice(sl);
    try buf.appendSlice("Content-Type: text/plain\r\n");
    const cl = try allocator.print("Content-Length: {d}\r\n", .{reason_phrase.len + 1});
    defer allocator.free(cl);
    try buf.appendSlice(cl);
    try buf.appendSlice("Connection: close\r\n\r\n");
    try buf.appendSlice(reason_phrase);
    try buf.append('\n');
    _ = socket.writeAll(buf.items) catch {};
}

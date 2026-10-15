const std = @import("std");
const curl = @import("curl");
const httpx = @import("httpx");
const tcp = httpx.tcp;
const parser = httpx.http1.parser;
const config_mod = @import("config");
const router_mod = @import("router");
const headers_mod = @import("headers");

const log = std.log.scoped(.forward);

const Self = @This();

config: *const config_mod.Config,
router: router_mod.Router,
verbose: bool,

pub const Forwarder = Self;

pub fn init(config: *const config_mod.Config, verbose: bool) !Self {
    return .{
        .config = config,
        .router = router_mod.Router.init(config.upstream),
        .verbose = verbose,
    };
}

/// Handle one client connection. Runs on its own thread; the caller owns and
/// closes the socket. Errors are logged (or swallowed for benign close).
pub fn handle(self: *Self, allocator: std.mem.Allocator, socket: *tcp.Socket) void {
    self.forward(allocator, socket) catch |err| {
        switch (err) {
            // Benign close, and upstream errors already reported by forward().
            error.ClientClosed, error.OutOfMemory, error.Curl => {},
            else => log.err("request error: {any}", .{ err }),
        }
    };
}

const BodyMode = enum { none, socket, buffer };

/// Per-connection state shared with the three libcurl callbacks. `tail` and
/// `body_buffer` are owned here (freed in deinit); `socket`/`response_overrides`
/// borrow from the caller.
const Ctx = struct {
    socket: *const tcp.Socket,
    allocator: std.mem.Allocator,
    body_mode: BodyMode,
    tail: []const u8,
    tail_pos: usize,
    body_remaining: usize,
    body_buffer: []const u8,
    body_buffer_pos: usize,
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

    fn deinit(self: *Ctx) void {
        if (self.tail.len > 0) self.allocator.free(self.tail);
        if (self.body_buffer.len > 0) self.allocator.free(self.body_buffer);
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
                const n = try self.socket.read(out[0..want]);
                self.body_remaining -= n;
                return n;
            },
            .buffer => {
                const avail = self.body_buffer.len - self.body_buffer_pos;
                const want = @min(avail, out.len);
                if (want == 0) return 0;
                @memcpy(out[0..want], self.body_buffer[self.body_buffer_pos..][0..want]);
                self.body_buffer_pos += want;
                return want;
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
        const n = socket.read(head_buf[total..]) catch return error.ClientClosed;
        if (n == 0) return error.ClientClosed;
        total += n;
        const buf = head_buf[0..total];
        head_res = parser.parseRequestHead(buf, .{}) catch |err| switch (err) {
            parser.ParseError.Incomplete => continue,
            else => return error.BadRequest,
        };
        blk = parser.parseHeaderBlock(buf, head_res.headEnd, &fields, .{}) catch |err| switch (err) {
            parser.ParseError.Incomplete => continue,
            else => return error.BadRequest,
        };
        break :read_head;
    }
    const field_slice = fields[0..blk.count];
    const method = head_res.method;
    const path = head_res.path;
    const start = std.Io.Timestamp.now(socket.io, .awake);

    // 2. Route to an upstream (path rewrite).
    const route = self.router.resolve(path) orelse {
        try writeError(socket, allocator, 404);
        if (self.verbose) log.info("[proxy] {s:<7} {s} -> 404 ({d}us)", .{ method, path, elapsedUs(start, socket.io) });
        return;
    };
    const upstream = route.upstream;

    // 3. Build the upstream URL (normalized base prefix ++ rewritten rest).
    const remote_path = try router_mod.Router.splicedPath(allocator, route);
    defer allocator.free(remote_path);
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ upstream.host, remote_path });
    defer allocator.free(url);
    const url_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{ url }, 0);
    defer allocator.free(url_z);
    if (self.verbose) log.info("[proxy] {s:<7} {s} -> {s}", .{ method, path, url });

    // 4. Decide body framing from headers, never from the method: GET/DELETE/
    //    HEAD may carry a body too.
    const framing = parser.decideFraming(field_slice, false, 0, method.len) catch return error.BadRequest;

    // 5. Seed context with any body bytes already read alongside the head.
    const tail_start = blk.end;
    var ctx: Ctx = .{
        .socket = socket,
        .allocator = allocator,
        .body_mode = .none,
        .tail = &.{},
        .tail_pos = 0,
        .body_remaining = 0,
        .body_buffer = &.{},
        .body_buffer_pos = 0,
        .head_buf = std.array_list.Managed(u8).init(allocator),
        .head_done = false,
        .response_status = 0,
        .response_overrides = &upstream.response_headers.map,
        .default_origin = self.config.default_origin,
    };
    errdefer ctx.deinit();

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
            // Buffer+decode the whole chunked body (non-streaming).
            ctx.body_buffer = try readChunkedBody(allocator, socket, ctx.tail);
            ctx.body_mode = .buffer;
            ctx.body_remaining = ctx.body_buffer.len;
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
    const method_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{ method }, 0);
    defer allocator.free(method_z);
    // "auto" may fall back to HTTP/1.1, but only when the request body is
    // re-sendable (a .socket body is consumed from the client on the first pass).
    const can_fallback = std.mem.eql(u8, upstream.protocol, "auto") and ctx.body_mode != .socket;
    var use_fallback: bool = false;
    while (true) {
        const http_version: curl.Easy.HttpVersion = if (use_fallback)
            .http1_1
        else
            firstProtocol(upstream.protocol);
        self.attempt(allocator, &ctx, url_z, upstream, req_headers, method_z, http_version) catch |err| {
            if (can_fallback and !ctx.head_done and !use_fallback) {
                // Nothing reached the client; retry the same request over HTTP/1.1.
                resetForRetry(&ctx);
                use_fallback = true;
                continue;
            }
            if (err == error.Curl) {
                // Report the upstream failure with the libcurl reason so the log
                // says which upstream failed and why (e.g. "Timeout was reached").
                const detail = ctx.curl_error orelse "unknown libcurl error";
                log.err("upstream error: {s} {s} -> {s} ({s})", .{ method, path, url, detail });
            }
            if (!ctx.head_done) try writeError(socket, allocator, 502);
            return err;
        };
        break;
    }
    log.info("[proxy] {s:<4} {s:<32} -> {s:<32} {d} ({d}us)", .{ method, path, remote_path, ctx.response_status, elapsedUs(start, socket.io) });
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
    method_z: []const u8,
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
        const iface_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{ iface }, 0);
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
        try curl.checkCode(curl.libcurl.curl_easy_setopt(curl_handle, curl.libcurl.CURLOPT_INFILESIZE_LARGE, @as(c_long, @intCast(ctx.body_remaining))), &diag);
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
/// with a clean slate. Only safe when the request body is re-sendable (the
/// caller guarantees `body_mode != .socket`).
fn resetForRetry(ctx: *Ctx) void {
    ctx.head_done = false;
    ctx.response_status = 0;
    ctx.curl_error = null;
    ctx.head_buf.clearRetainingCapacity();
    ctx.body_buffer_pos = 0;
    ctx.tail_pos = 0;
    ctx.body_remaining = ctx.body_buffer.len;
}

/// Microseconds elapsed between `start` and now, read from the same clock.
fn elapsedUs(start: std.Io.Timestamp, io: std.Io) i64 {
    const ns = start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    return @intCast(@divTrunc(ns, 1000));
}

fn readCallback(buffer: ?*anyopaque, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
    const ud = user_data orelse return curl.libcurl.CURL_READFUNC_ABORT;
    const buf = buffer orelse return curl.libcurl.CURL_READFUNC_ABORT;
    const ctx: *Ctx = @alignCast(@ptrCast(ud));
    const max_len = size * nmemb;
    const ptr: [*]u8 = @ptrCast(buf);
    const out: []u8 = ptr[0..max_len];
    return ctx.readBody(out) catch curl.libcurl.CURL_READFUNC_ABORT;
}

fn writeCallback(buffer: ?*anyopaque, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
    const ud = user_data orelse return 0;
    const buf = buffer orelse return 0;
    const ctx: *Ctx = @alignCast(@ptrCast(ud));
    const n = size * nmemb;
    const ptr: [*]const u8 = @ptrCast(buf);
    const data: []const u8 = ptr[0..n];
    ctx.socket.writeAll(data) catch return 0;
    return n;
}

fn headerCallback(buffer: ?*anyopaque, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
    const ud = user_data orelse return 0;
    const buf = buffer orelse return 0;
    const ctx: *Ctx = @alignCast(@ptrCast(ud));
    const n = size * nmemb;
    const ptr: [*]const u8 = @ptrCast(buf);
    const data: []const u8 = ptr[0..n];
    if (ctx.head_done) return n; // ignore trailer bytes
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
        const head_res = parser.parseResponseHead(head_bytes, .{}) catch return 0;
        ctx.response_status = head_res.statusCode;
        const status_line = head_bytes[0 .. head_res.headEnd - 2];
        var fields: [parser.DEFAULT_MAX_HEADERS]parser.Field = undefined;
        const blk = parser.parseHeaderBlock(head_bytes, head_res.headEnd, &fields, .{}) catch return 0;
        const resp_head = headers_mod.buildResponseHead(ctx.allocator, status_line, fields[0..blk.count], ctx.response_overrides, ctx.default_origin) catch return 0;
        defer {
            if (http2_head) |s| ctx.allocator.free(s);
            ctx.allocator.free(resp_head);
        }
        ctx.socket.writeAll(resp_head) catch return 0;
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

/// Buffer and fully decode a chunked request body, returning the decoded
/// payload. `seed` holds the body bytes already read with the head; the rest is
/// read from the socket until the terminating chunk.
fn readChunkedBody(allocator: std.mem.Allocator, socket: *const tcp.Socket, seed: []const u8) ![]u8 {
    var work: []u8 = try allocator.alloc(u8, 16384);
    errdefer allocator.free(work);
    var work_len: usize = 0;
    var payload = std.array_list.Managed(u8).init(allocator);
    errdefer payload.deinit();
    if (seed.len > 0) {
        work = try ensureCap(work, 0, seed.len, allocator);
        @memcpy(work[0..seed.len], seed);
        work_len = seed.len;
    }
    var decoder = parser.ChunkedDecoder.init();
    while (true) {
        var done = false;
        const res = decoder.decode(work[0..work_len]);
        if (res) |_| {
            done = true;
        } else |err| {
            if (err != parser.ParseError.Incomplete) return err;
            // Incomplete: keep `done` false and read more below.
        }
        const decoded = decoder.decodedLen;
        const consumed = decoder.rawConsumed;
        if (decoded > 0) try payload.appendSlice(work[0..decoded]);
        // Drop the consumed prefix; the unconsumed remainder becomes the seed
        // for the next round.
        const keep = work_len - consumed;
        if (keep > 0) std.mem.copyForwards(u8, work[0..keep], work[consumed..work_len]);
        work_len = keep;
        if (done) break;
        work = try ensureCap(work, work_len, work_len + 8192, allocator);
        const n = socket.read(work[work_len..]) catch return error.ClientClosed;
        if (n == 0) return error.ChunkedBodyIncomplete;
        work_len += n;
    }
    return payload.toOwnedSlice();
}

fn ensureCap(buf: []u8, used: usize, want: usize, allocator: std.mem.Allocator) ![]u8 {
    if (buf.len >= want) return buf;
    var cap = buf.len;
    while (cap < want) cap *= 2;
    const newbuf = try allocator.alloc(u8, cap);
    @memcpy(newbuf[0..used], buf[0..used]);
    allocator.free(buf);
    return newbuf;
}

fn writeError(socket: *const tcp.Socket, allocator: std.mem.Allocator, code: u16) !void {
    const reason_phrase = switch (code) {
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        else => "Error",
    };
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    const sl = try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\n", .{ code, reason_phrase });
    defer allocator.free(sl);
    try buf.appendSlice(sl);
    try buf.appendSlice("Content-Type: text/plain\r\n");
    const cl = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n", .{ reason_phrase.len + 1 });
    defer allocator.free(cl);
    try buf.appendSlice(cl);
    try buf.appendSlice("Connection: close\r\n\r\n");
    try buf.appendSlice(reason_phrase);
    try buf.append('\n');
    _ = socket.writeAll(buf.items) catch {};
}

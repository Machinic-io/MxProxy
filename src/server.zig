const std = @import("std");
const httpx = @import("httpx");
const tcp = httpx.tcp;
const tls = httpx.tls;
const address = httpx.net.address;
const posix = std.posix;
const stream_mod = @import("stream");
const forward_mod = @import("forward");

const log = std.log.scoped(.server);

/// ALPN protocols the TLS listener offers. The forwarder speaks HTTP/1.1 only,
/// so h2 must NOT be offered: a client that negotiates h2 would speak HTTP/2
/// framing over a connection the proxy answers with HTTP/1.1.
const ALPN_HTTP11 = [_]tls.alpn.Protocol{.@"http/1.1"};

/// Global pointer to the running server, used by the signal handler. Written
/// once (before serving), read from signal context, and cleared again after
/// run() returns — so both accesses are atomic to keep the handler safe.
var g_server: ?*Server = null;

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    if (@atomicLoad(?*Server, &g_server, .monotonic)) |s| {
        if (s.requestShutdown()) {
            // A repeat signal while shutdown is already in progress: the
            // graceful path is stuck (its wake connection could not land) or
            // the user is pressing again — either way, stop NOW. _exit, not
            // exit(): we are in signal context, where atexit handlers and
            // stdio flushing are not safe.
            std.c._exit(130); // 128 + SIGINT: the conventional signal death
        }
    }
}

/// Accept loop + thread-per-connection + signal-driven shutdown.
pub const Server = struct {
    const Self = @This();

    forwarder: *forward_mod.Forwarder,
    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    /// Client-facing listen address; `null` means all interfaces (0.0.0.0).
    bind_address: ?[]const u8 = null,
    /// Local-side TLS material (PEM string or file path), from
    /// `Config.tls_certificate`/`Config.tls_private_key`. Both set → the port
    /// auto-detects TLS vs plain HTTP per connection; both null → plain only
    /// (validation guarantees they are never set independently).
    tls_certificate: ?[]const u8 = null,
    tls_private_key: ?[]const u8 = null,
    /// The resolved address actually bound in run(); used to wake accept().
    /// Defaults to any/0 so a signal before run() binds stays harmless.
    bound_address: address.Address = .{ .family = .ip4, .port = 0 },
    /// Shutdown signals received: 0 = running, 1 = graceful shutdown requested
    /// (the accept loop stops), 2+ = a repeat signal arrived while shutdown
    /// was in progress (the handler hard-exits on it, so the accept loop
    /// never observes 2+). Written by the signal handler and read by the
    /// accept loop, so accessed atomically.
    signal_count: std.atomic.Value(u32) = .init(0),

    pub fn init(forwarder: *forward_mod.Forwarder, allocator: std.mem.Allocator, io: std.Io) Self {
        return .{ .forwarder = forwarder, .allocator = allocator, .io = io, .port = forwarder.config.port, .bind_address = forwarder.config.bind_address, .tls_certificate = forwarder.config.tls_certificate, .tls_private_key = forwarder.config.tls_private_key };
    }

    /// Install SIGINT/SIGTERM handlers that request a graceful shutdown.
    pub fn registerSignalHandlers(self: *Self) void {
        @atomicStore(?*Server, &g_server, self, .monotonic);
        var sig_act: posix.Sigaction = std.mem.zeroes(posix.Sigaction);
        sig_act.handler = .{ .handler = @ptrCast(&handleSignal) };
        sig_act.flags = 0;
        _ = posix.sigaction(posix.SIG.INT, &sig_act, null);
        _ = posix.sigaction(posix.SIG.TERM, &sig_act, null);
    }

    /// Clear the global pointer and restore default SIGINT/SIGTERM handling so
    /// a signal arriving after run() returns cannot dereference a stale server
    /// pointer. Call once, after the accept loop exits.
    pub fn deregisterSignalHandlers(self: *Self) void {
        _ = self;
        @atomicStore(?*Server, &g_server, null, .monotonic);
        var sig_act: posix.Sigaction = std.mem.zeroes(posix.Sigaction);
        sig_act.handler = .{ .handler = posix.SIG.DFL };
        sig_act.flags = 0;
        _ = posix.sigaction(posix.SIG.INT, &sig_act, null);
        _ = posix.sigaction(posix.SIG.TERM, &sig_act, null);
    }

    /// Request a graceful shutdown: count the signal and, on the first one,
    /// wake the blocked accept() with a throwaway connection. Returns true
    /// when a shutdown was ALREADY requested, i.e. this is a repeat signal
    /// (the handler hard-exits on it). All operations are async-signal-safe
    /// (an atomic fetch-add plus socket/connect syscalls), so this may run in
    /// signal context.
    pub fn requestShutdown(self: *Self) bool {
        const n = self.signal_count.fetchAdd(1, .release);
        if (n == 0) wakeListener(self.bound_address);
        return n != 0;
    }

    /// Bind, serve, and block until requestShutdown() is called.
    pub fn run(self: *Self) !void {
        // A signal may have arrived before run(): its wake connection could
        // not have landed (there was no listener to connect to). Bail before
        // binding so a Ctrl+C during startup stops the process instantly.
        if (self.signal_count.load(.acquire) != 0) return;

        // Local-side TLS: built once, before binding, so invalid cert/key
        // material fails at startup (httpx's tls.Server.init validates the
        // identity) instead of at first handshake. The server is shared by
        // every connection thread; its accept() is concurrency-safe.
        //
        // Config values are file paths or inline PEM; they are resolved to
        // PEM content here, before init. httpx's Server.init validates a path
        // but the handshake path (`resolveIdentity`) uses the configured
        // string verbatim — feeding it a raw path fails mid-handshake (the
        // DER parser rejects the path text with a ProtocolViolation). So the
        // caller must hand the server real PEM content either way. The
        // resolved buffers are borrowed by the server for its whole lifetime;
        // the `defer` order below frees them only after `tls_server.deinit()`.
        var tls_server: ?*tls.Server = null;
        var tls_cert_buf: ?[]u8 = null;
        var tls_key_buf: ?[]u8 = null;
        defer if (tls_cert_buf) |b| self.allocator.free(b);
        defer if (tls_key_buf) |b| {
            std.crypto.secureZero(u8, b);
            self.allocator.free(b);
        };
        defer if (tls_server) |ts| {
            ts.deinit();
            self.allocator.destroy(ts);
        };
        if (self.tls_certificate) |cert_src| {
            if (self.tls_private_key) |key_src| {
                tls_cert_buf = loadPemOrPath(self.allocator, self.io, cert_src) catch |err| {
                    log.err("cannot load TLS certificate material: {any}", .{err});
                    return err;
                };
                tls_key_buf = loadPemOrPath(self.allocator, self.io, key_src) catch |err| {
                    log.err("cannot load TLS private key material: {any}", .{err});
                    return err;
                };
                const ts = self.allocator.create(tls.Server) catch return error.OutOfMemory;
                ts.* = tls.Server.init(self.allocator, self.io, .{
                    .certificatePem = tls_cert_buf.?,
                    .privateKeyPem = tls_key_buf.?,
                    .alpn = &ALPN_HTTP11,
                }) catch |err| {
                    // No `defer` covers this yet (tls_server is still null), so
                    // free the uninitialized allocation here before returning.
                    self.allocator.destroy(ts);
                    log.err("TLS startup failed (certificate/key invalid or unreadable): {any}", .{err});
                    return err;
                };
                tls_server = ts;
                log.info("https enabled: TLS 1.3 (ALPN http/1.1); plain HTTP is also served on this port", .{});
            }
        }

        const listener = try self.allocator.create(tcp.Listener);
        var bound = false;
        defer {
            if (bound) listener.close(self.io);
            self.allocator.destroy(listener);
        }

        var bind_addr: address.Address = blk: {
            if (self.bind_address) |bind_ip| {
                const seed = address.Address.unspecified4(self.port);
                break :blk seed.parseIp(bind_ip) catch {
                    log.err("invalid bind address: {s}", .{bind_ip});
                    return error.InvalidBindAddress;
                };
            } else {
                break :blk address.Address.unspecified4(self.port);
            }
        };
        bind_addr.port = self.port;
        self.bound_address = bind_addr;

        var addr_buf: [64]u8 = undefined;
        listener.* = tcp.Listener.bindAddress(self.io, &bind_addr) catch |err| {
            log.err("failed to bind {s}:{d}: {any}", .{ bind_addr.formatBuf(&addr_buf), self.port, err });
            return err;
        };
        bound = true;
        // Record the port the listener actually bound (it differs from
        // self.port only for port-0/ephemeral binds) so the wake connection
        // targets the address the listener listens on.
        self.bound_address.port = listener.localPort();
        log.info("listening on {s}:{d}", .{ bind_addr.formatBuf(&addr_buf), listener.localPort() });

        // A signal in the bind window above may have woken nothing (the
        // listener was not up when its wake fired). Bail before blocking on
        // accept; the loop below would otherwise block until some client
        // happened to connect.
        if (self.signal_count.load(.acquire) != 0) return;

        while (true) {
            const socket = listener.accept(self.io) catch |err| {
                // A wake or the shutdown itself can surface as an accept error;
                // if shutdown was requested treat it as a clean stop.
                if (self.signal_count.load(.acquire) != 0) return;
                log.err("accept: {any}", .{err});
                return err;
            };
            if (self.signal_count.load(.acquire) != 0) {
                socket.close();
                log.info("shutting down", .{});
                return; // shutdown requested
            }
            const t = std.Thread.spawn(.{}, handleConn, .{ self.forwarder, self.allocator, socket, tls_server }) catch {
                socket.close();
                log.err("failed to spawn connection thread", .{});
                continue;
            };
            // Detach: this thread is fire-and-forget (one connection), so we
            // never join it. Detaching releases the pthread's resources when it
            // exits, instead of leaking a zombie joinable thread per connection.
            t.detach();
        }
    }
};

/// Wake the blocked accept() by connecting a throwaway socket to the address
/// the listener is bound to. Async-signal-safe: only socket()/connect()/close()
/// syscalls, no allocation, so it may run from the signal handler.
///
/// An "any" bind (0.0.0.0 / ::) is not a connect target, so we use the
/// same-family loopback instead, which still reaches the any-bound socket.
/// Binding to a concrete local address is always reachable from this host, so
/// graceful shutdown works for --bind to any local IP (loopback or not).
fn wakeListener(bound: address.Address) void {
    var target = bound;
    const n: usize = if (bound.family == .ip4) 4 else 16;
    const zero = std.mem.zeroes([16]u8);
    if (std.mem.eql(u8, bound.bytes[0..n], zero[0..n])) {
        target = switch (bound.family) {
            .ip4 => address.Address.loopback4(bound.port),
            .ip6 => address.Address.loopback6(bound.port),
        };
    }

    const domain: c_uint = if (target.family == .ip4) @as(c_uint, posix.AF.INET) else @as(c_uint, posix.AF.INET6);
    const fd = std.c.socket(domain, @as(c_uint, posix.SOCK.STREAM), 0);
    if (fd < 0) return;
    defer _ = std.c.close(fd);

    switch (target.family) {
        .ip4 => {
            const ip = (@as(u32, target.bytes[0]) << 24) |
                (@as(u32, target.bytes[1]) << 16) |
                (@as(u32, target.bytes[2]) << 8) |
                @as(u32, target.bytes[3]);
            const sa = posix.sockaddr.in{
                .port = std.mem.nativeToBig(u16, target.port),
                .addr = std.mem.nativeToBig(u32, ip),
            };
            _ = std.c.connect(fd, @ptrCast(&sa), @sizeOf(posix.sockaddr.in));
        },
        .ip6 => {
            const sa = posix.sockaddr.in6{
                .port = std.mem.nativeToBig(u16, target.port),
                .flowinfo = 0,
                .addr = target.bytes,
                .scope_id = 0,
            };
            _ = std.c.connect(fd, @ptrCast(&sa), @sizeOf(posix.sockaddr.in6));
        },
    }
}

/// True when `prefix` starts a TLS record: the first flight of a handshake is
/// always a handshake record (0x16) with the 0x03 0x01..0x03 legacy version.
/// HTTP request methods and the HTTP/2 preface start with ASCII letters, so
/// three bytes distinguish TLS from plain HTTP without ambiguity (the same
/// rule httpx.Server uses for its own shared-port dispatch).
fn looksLikeTls(prefix: []const u8) bool {
    return prefix.len >= 3 and prefix[0] == 0x16 and prefix[1] == 0x03 and prefix[2] <= 0x03;
}

/// Resolve TLS material configured as either form: inline PEM (anything
/// containing a `-----BEGIN` marker — the same rule httpx applies internally)
/// or a path to a PEM file, read into an allocator-owned buffer. Inline PEM
/// is duped so the caller frees both forms uniformly.
fn loadPemOrPath(allocator: std.mem.Allocator, io: std.Io, src: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, src, "-----BEGIN") != null) return allocator.dupe(u8, src);
    return std.Io.Dir.cwd().readFileAlloc(io, src, allocator, .unlimited);
}

/// Per-connection entry point. With TLS configured, the first bytes are read
/// to classify the connection: a TLS record starts a TLS handshake (the peeked
/// bytes seed `acceptBuffered`); anything else is plain HTTP (the peeked bytes
/// seed the forwarder's request-head read, so they are not lost). Without TLS,
/// the connection is plain with nothing pre-read.
fn handleConn(forwarder: *forward_mod.Forwarder, allocator: std.mem.Allocator, socket: tcp.Socket, tls_server: ?*tls.Server) void {
    var s = socket;
    defer s.close();
    if (tls_server) |ts| {
        // Read enough bytes to classify. The 3-byte buffer can never swallow
        // more of the stream than detection needs: whatever is not read here
        // stays in the socket for the forwarder (or the handshake) to consume.
        var peek: [3]u8 = undefined;
        var n: usize = 0;
        while (n < peek.len) {
            const r = s.read(peek[n..]) catch return; // dead peer: nothing to serve
            if (r == 0) break; // EOF before 3 bytes: too short to classify
            n += r;
        }
        if (n == 0) return;
        if (looksLikeTls(peek[0..n])) {
            var conn = ts.acceptBuffered(&s, peek[0..n]) catch |err| {
                // Routine noise (scanners, probes, clients our TLS 1.3-only
                // engine cannot satisfy): info, not error.
                log.info("tls handshake failed: {any}", .{err});
                return;
            };
            defer conn.deinit();
            if (conn.alpn) |proto| {
                // The server only offers http/1.1, so this is belt-and-
                // braces: never relay HTTP/1.1 onto a connection the client
                // believes is HTTP/2.
                if (proto != .@"http/1.1") {
                    log.info("rejecting connection: negotiated ALPN \"{s}\" is not supported", .{proto.wireName()});
                    return;
                }
            }
            var stream = stream_mod.Stream.wrapped(&conn);
            forwarder.handle(allocator, &stream, &.{});
        } else {
            var stream = stream_mod.Stream.plain(&s);
            forwarder.handle(allocator, &stream, peek[0..n]);
        }
    } else {
        var stream = stream_mod.Stream.plain(&s);
        forwarder.handle(allocator, &stream, &.{});
    }
}

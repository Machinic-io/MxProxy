const std = @import("std");
const httpx = @import("httpx");
const tcp = httpx.tcp;
const address = httpx.address;
const posix = std.posix;
const forward_mod = @import("forward");

const log = std.log.scoped(.server);

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
        return .{ .forwarder = forwarder, .allocator = allocator, .io = io, .port = forwarder.config.port, .bind_address = forwarder.config.bind_address };
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
            const t = std.Thread.spawn(.{}, handleConn, .{ self.forwarder, self.allocator, socket }) catch {
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

fn handleConn(forwarder: *forward_mod.Forwarder, allocator: std.mem.Allocator, socket: tcp.Socket) void {
    var s = socket;
    forwarder.handle(allocator, &s);
    s.close();
}

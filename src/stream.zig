//! Client-facing connection abstraction for the proxy: either a plain TCP
//! socket or a TLS-wrapped connection (httpx's native TLS server engine),
//! unified behind the `read`/`writeAll` pair the forwarder already uses.
//!
//! The forwarder treats every read/write failure as "the client went away"
//! (`error.ClientClosed`), so TLS and socket errors are mapped onto that
//! semantic here; allocation failures stay distinguishable as OOM.

const std = @import("std");
const httpx = @import("httpx");
const tcp = httpx.tcp;
const tls = httpx.tls;

/// The error set a `Stream` read/write surfaces to the forwarder.
pub const StreamError = error{ ClientClosed, OutOfMemory };

pub const Stream = struct {
    const Self = @This();

    pub const Inner = union(enum) {
        plain: *tcp.Socket,
        tls: *tls.Server.Connection,
    };

    inner: Inner,
    /// The I/O instance of the underlying socket (the forwarder reads clocks
    /// through this, as it used to through `tcp.Socket.io`).
    io: std.Io,

    pub fn plain(socket: *tcp.Socket) Self {
        return .{ .inner = .{ .plain = socket }, .io = socket.io };
    }

    pub fn wrapped(conn: *tls.Server.Connection) Self {
        return .{ .inner = .{ .tls = conn }, .io = conn.socket.io };
    }

    pub fn read(self: *Self, buf: []u8) StreamError!usize {
        switch (self.inner) {
            .plain => |s| return s.read(buf) catch error.ClientClosed,
            .tls => |c| return c.read(buf) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ClientClosed,
            },
        }
    }

    pub fn writeAll(self: *Self, data: []const u8) StreamError!void {
        switch (self.inner) {
            .plain => |s| return s.writeAll(data) catch error.ClientClosed,
            .tls => |c| return c.writeAll(data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ClientClosed,
            },
        }
    }
};

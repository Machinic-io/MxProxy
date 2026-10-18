const std = @import("std");
const httpx = @import("httpx");

/// One parsed header name/value pair.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Override map shared with `config.HeaderOverrides.map`: key = header name,
/// value = null (delete) or a string (set to this). An absent name passes
/// through unchanged.
pub const OverrideMap = std.StringArrayHashMapUnmanaged(?[]const u8);

/// Connection-specific / framing headers that libcurl manages and that must
/// not be relayed verbatim in either direction. They are dropped even when a
/// per-upstream override names them (libcurl must own the framing).
const hop_by_hop = [_][]const u8{
    "Connection", "Keep-Alive",     "Proxy-Authenticate", "Proxy-Authorization",
    "TE",         "Trailer",        "Trailers",           "Transfer-Encoding",
    "Upgrade",    "Content-Length",
};

pub fn isHopByHop(name: []const u8) bool {
    for (hop_by_hop) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

/// Request headers libcurl synthesizes for the upstream transfer. The
/// client's values are dropped, but — unlike hop-by-hop headers — a
/// per-upstream override may replace libcurl's default: libcurl honors a
/// header-list entry for these (it suppresses its own default when one is
/// supplied).
fn isManagedRequest(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "Host") or std.ascii.eqlIgnoreCase(name, "User-Agent");
}

/// Request headers the proxy itself manages and never relays to the upstream,
/// even via override. Expect is answered by the proxy itself (it sends
/// `100 Continue` to the client; see forward.zig).
fn isProxyManaged(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "Expect");
}

/// A header is forwardable if the http1 writer can serialize it (name/value
/// length + character limits). Skipping non-forwardable headers avoids making
/// the whole response fail to serialize.
pub fn isForwardable(name: []const u8, value: []const u8) bool {
    return httpx.http1.writer.validToken(name) and httpx.http1.writer.validHeaderValue(value);
}

/// True if the header is Access-Control-Allow-Origin (case-insensitive).
fn isAccessControlAllowOrigin(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "Access-Control-Allow-Origin");
}

/// True if the header is Origin (case-insensitive).
fn isOrigin(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "Origin");
}

fn nameInFields(fields: []const httpx.http1.parser.Field, name: []const u8) bool {
    for (fields) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) return true;
    }
    return false;
}

fn allocHeaderLine(allocator: std.mem.Allocator, name: []const u8, value: []const u8) ![:0]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice(name);
    try buf.append(':');
    try buf.append(' ');
    try buf.appendSlice(value);
    try buf.append(0);
    return buf.toOwnedSliceSentinel(0);
}

/// Build "Name: Value" lines for CURLOPT_HTTPHEADER from the parsed client
/// request headers, applying the upstream's request overrides.
///
/// Framing (hop-by-hop) headers and Expect are dropped and cannot be
/// overridden (libcurl and the proxy manage them; the proxy answers
/// 100-continue itself). Host and User-Agent get libcurl defaults (the URL
/// host and "MxProxy"); a per-upstream override replaces the default, and a
/// null override keeps libcurl's default. Accept-Encoding is relayed verbatim
/// so the upstream can compress for the actual client.
/// The client's Origin header is swapped for `request_origin` (the upstream's
/// own origin) so the upstream sees a same-origin request; a per-upstream
/// override of Origin (in `overrides`) wins if set.
/// The returned slice and each of its NUL-terminated strings are owned by the
/// caller's allocator.
pub fn buildRequestHeaders(
    allocator: std.mem.Allocator,
    fields: []const httpx.http1.parser.Field,
    overrides: *const OverrideMap,
    request_origin: []const u8,
) ![][:0]const u8 {
    var out = std.array_list.Managed([:0]const u8).init(allocator);
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit();
    }

    for (fields) |f| {
        // Framing and proxy-managed headers are never relayed, even under an
        // override.
        if (isHopByHop(f.name) or isProxyManaged(f.name)) continue;
        if (isManagedRequest(f.name)) {
            // libcurl sets a default Host (from the URL) and User-Agent; an
            // override replaces it, a null override keeps the default.
            if (overrides.get(f.name)) |v| {
                if (v) |newval| {
                    if (!isForwardable(f.name, newval)) continue;
                    try out.append(try allocHeaderLine(allocator, f.name, newval));
                }
            }
            continue;
        }
        if (!isForwardable(f.name, f.value)) continue;
        if (overrides.get(f.name)) |v| {
            if (v) |newval| {
                if (!isForwardable(f.name, newval)) continue;
                try out.append(try allocHeaderLine(allocator, f.name, newval));
            } // v == null => delete
        } else if (isOrigin(f.name)) {
            // Swap the client's Origin for the upstream's own origin so the
            // upstream sees a same-origin request; a per-upstream override
            // (handled above) wins if set.
            try out.append(try allocHeaderLine(allocator, f.name, request_origin));
        } else {
            try out.append(try allocHeaderLine(allocator, f.name, f.value));
        }
    }

    var it = overrides.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        const v = kv.value_ptr.*;
        if (v == null) continue; // delete-only override, no original header
        if (isHopByHop(name) or isProxyManaged(name)) continue;
        if (nameInFields(fields, name) and !isManagedRequest(name)) continue; // handled above
        if (!isForwardable(name, v.?)) continue;
        try out.append(try allocHeaderLine(allocator, name, v.?));
    }

    return out.toOwnedSlice();
}

/// Build the full response head to write to the client: the upstream status
/// line verbatim, the transformed header lines (hop-by-hop dropped,
/// Content-Encoding relayed verbatim, overrides applied, non-forwardable
/// skipped), and the terminating blank line. The returned buffer is owned by
/// the caller's allocator.
///
/// When the upstream response carries Access-Control-Allow-Origin, its value is
/// swapped for the configured CORS value so the caller's browser accepts the
/// response: a per-upstream override (in `overrides`) wins, else `default_origin`
/// (`--access-control-allow-origin`), else `"*"`.
pub fn buildResponseHead(
    allocator: std.mem.Allocator,
    status_line: []const u8,
    fields: []const httpx.http1.parser.Field,
    overrides: *const OverrideMap,
    default_origin: ?[]const u8,
) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice(status_line);
    try buf.appendSlice("\r\n");

    for (fields) |f| {
        if (shouldDropResponse(f.name)) continue;
        if (!isForwardable(f.name, f.value)) continue;
        if (overrides.get(f.name)) |v| {
            if (v) |newval| {
                if (!isForwardable(f.name, newval)) continue;
                try appendLine(&buf, f.name, newval);
            }
            // v == null => delete
        } else if (isAccessControlAllowOrigin(f.name)) {
            // The upstream advertised an origin for CORS. Swap it for the
            // configured value so the caller's browser accepts the response:
            // the per-upstream override already won above if set, otherwise use
            // the --access-control-allow-origin default, else "*".
            const origin = default_origin orelse "*";
            if (!isForwardable(f.name, origin)) continue;
            try appendLine(&buf, f.name, origin);
        } else {
            try appendLine(&buf, f.name, f.value);
        }
    }

    var it = overrides.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        const v = kv.value_ptr.*;
        if (v == null) continue;
        if (shouldDropResponse(name)) continue;
        if (nameInFields(fields, name)) continue;
        if (!isForwardable(name, v.?)) continue;
        try appendLine(&buf, name, v.?);
    }

    // The proxy closes the client connection after every response and relays
    // the body without Content-Length (dropped as hop-by-hop), so the body is
    // delimited by connection close. Advertise that explicitly; a keep-alive
    // client otherwise cannot tell the body ends at EOF.
    try appendLine(&buf, "Connection", "close");

    try buf.appendSlice("\r\n"); // blank line terminating the head
    return buf.toOwnedSlice();
}

fn appendLine(buf: *std.array_list.Managed(u8), name: []const u8, value: []const u8) !void {
    try buf.appendSlice(name);
    try buf.append(':');
    try buf.append(' ');
    try buf.appendSlice(value);
    try buf.appendSlice("\r\n");
}

fn shouldDropResponse(name: []const u8) bool {
    // Content-Encoding is relayed verbatim: libcurl does not decode (the
    // Accept-Encoding option is left unset), so the header still describes the
    // forwarded bytes and the client decompresses them.
    if (isHopByHop(name)) return true;
    return false;
}

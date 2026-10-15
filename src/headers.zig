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
/// not be relayed verbatim in either direction.
const hop_by_hop = [_][]const u8{
    "Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization",
    "TE", "Trailer", "Trailers", "Transfer-Encoding", "Upgrade",
    "Content-Length",
};

pub fn isHopByHop(name: []const u8) bool {
    for (hop_by_hop) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
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
/// libcurl owns Host, User-Agent and the framing headers, so those are dropped
/// from the relayed set (an override may still set them). Accept-Encoding is
/// relayed verbatim so the upstream can compress for the actual client.
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
        if (shouldDropRequest(f.name)) continue;
        if (!isForwardable(f.name, f.value)) continue;
        if (overrides.get(f.name)) |v| {
            if (v) |newval| {
                try out.append(try allocHeaderLine(allocator, f.name, newval));
            }
            // v == null => delete
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
        if (shouldDropRequest(name)) continue;
        if (nameInFields(fields, name)) continue; // already handled above
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
                try appendLine(&buf, f.name, newval);
            }
            // v == null => delete
        } else if (isAccessControlAllowOrigin(f.name)) {
            // The upstream advertised an origin for CORS. Swap it for the
            // configured value so the caller's browser accepts the response:
            // the per-upstream override already won above if set, otherwise use
            // the --access-control-allow-origin default, else "*".
            try appendLine(&buf, f.name, default_origin orelse "*");
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

fn shouldDropRequest(name: []const u8) bool {
    if (isHopByHop(name)) return true;
    if (std.ascii.eqlIgnoreCase(name, "Host")) return true;
    if (std.ascii.eqlIgnoreCase(name, "User-Agent")) return true;
    // Accept-Encoding is relayed so upstream can compress for the actual client.
    // libcurl is not asked to decode (CURLOPT_ACCEPT_ENCODING unset), so the
    // compressed body is forwarded verbatim with Content-Encoding intact.
    return false;
}

fn shouldDropResponse(name: []const u8) bool {
    // Content-Encoding is relayed verbatim: libcurl does not decode (the
    // Accept-Encoding option is left unset), so the header still describes the
    // forwarded bytes and the client decompresses them.
    if (isHopByHop(name)) return true;
    return false;
}

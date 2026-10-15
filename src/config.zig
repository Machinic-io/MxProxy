const std = @import("std");

pub const ConfigError = error{
    InvalidPort,
    MissingHost,
    InvalidHost,
    InvalidPathType,
    InvalidProtocol,
    UpstreamHostConflict,
    ConfigFileNotFound,
    InvalidConfig,
};

/// Header overrides for a single direction.
///
/// Decoded from a JSON object whose keys are header names. A value of `null`
/// means "delete this header"; a string value means "set it to this". A header
/// name absent from the object is passed through unchanged.
pub const HeaderOverrides = std.json.ArrayHashMap(?[]const u8);

/// A single path rewrite rule. `local` is the client-facing prefix, `remote`
/// the upstream prefix it maps to. Only "plain" (prefix) matching is supported
/// for now; the type field keeps the schema open for "regex" later.
///
/// A `local` of `""` or `"/"` matches any path (a wildcard/catch-all rule).
/// `remote` may be `""`, `"/"`, or omitted; all mean the upstream origin
/// (root), so the request path passes through under the host with the matched
/// `local` prefix removed. `remote` and the remainder are joined into a clean
/// absolute path (see `Router.splicedPath`), so a root remote never doubles
/// the leading slash.
pub const PathMapping = struct {
    @"type": []const u8,
    local: []const u8,
    remote: []const u8 = "",
};

/// One upstream server. `host` is the full origin URL (scheme://authority).
pub const Upstream = struct {
    host: []const u8,

    /// Upstream-facing network interface (e.g. "eth0"). `null` means inherit
    /// the top-level default interface.
    interface: ?[]const u8 = null,

    /// Upstream request timeout in milliseconds. `null` means inherit the
    /// top-level default timeout (see `Config.timeout_ms`).
    timeout_ms: ?usize = null,
    /// Skip TLS certificate verification. `null` means inherit the top-level
    /// default (see `Config.insecure`).
    insecure: ?bool = null,

    /// Upstream HTTP protocol: "http1", "http2", or "auto" (default). "auto"
    /// negotiates HTTP/2 over TLS when the upstream supports it and falls back
    /// to HTTP/1.1 if the transfer fails before anything is sent to the client.
    protocol: []const u8 = "auto",

    /// Applied to request headers sent to the upstream.
    request_headers: HeaderOverrides = .{ .map = .empty },

    /// Applied to response headers sent back to the client.
    response_headers: HeaderOverrides = .{ .map = .empty },

    /// Path rewrite rules, first match wins.
    path: []const PathMapping = &.{},

    /// The effective upstream-facing interface, falling back to `default`.
    pub fn effectiveInterface(self: *const Upstream, default: ?[]const u8) ?[]const u8 {
        return self.interface orelse default;
    }

    /// The effective upstream request timeout in milliseconds, falling back to
    /// `default` (the top-level default timeout).
    pub fn effectiveTimeoutMs(self: *const Upstream, default: usize) usize {
        return self.timeout_ms orelse default;
    }

    /// Whether TLS certificate verification is skipped, falling back to
    /// `default` (the top-level default).
    pub fn effectiveInsecure(self: *const Upstream, default: bool) bool {
        return self.insecure orelse default;
    }

    /// The origin (scheme://authority) of this upstream's host, with any path
    /// stripped. Used to override the request Origin header so the upstream
    /// sees a request originating from itself.
    pub fn origin(self: *const Upstream) []const u8 {
        const host = self.host;
        if (std.mem.indexOf(u8, host, "://")) |scheme_end| {
            const after_scheme = scheme_end + 3;
            if (std.mem.indexOfScalar(u8, host[after_scheme..], '/')) |path_start| {
                return host[0 .. after_scheme + path_start];
            }
        }
        return host;
    }
};

/// JSON-decodable configuration. All fields optional so the same type decodes
/// both the config file (top-level, port optional) and the inline
/// `--config-json` string override (top-level keys only).
const RawConfig = struct {
    port: ?u16 = null,
    bind_address: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    timeout_ms: ?usize = null,
    insecure: ?bool = null,
    upstream: ?[]Upstream = null,
};

/// The catch-all path rule assumed by the `--upstream-host` override.
const CatchAllPath = [_]PathMapping{ .{ .@"type" = "plain", .local = "", .remote = "" } };

/// Validate an upstream origin URL: non-empty and a full `scheme://authority`
/// URL. A malformed origin (e.g. "https:example.com", missing the "//") would
/// otherwise slip past startup and fail per-request with CURLE_URL_MALFORMAT.
fn validateHost(host: []const u8) !void {
    if (host.len == 0) return ConfigError.MissingHost;
    if (std.mem.indexOf(u8, host, "://") == null) return ConfigError.InvalidHost;
}

/// The resolved, validated runtime configuration.
///
/// Owns every string/slice it references through an internal arena, so a
/// `deinit` releases everything at once and the top-level merge (file vs
/// inline string) never needs per-field freeing.
pub const Config = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,

    port: u16 = 8080,
    /// Client-facing listen address (e.g. "127.0.0.1"). `null` means all
    /// interfaces (0.0.0.0). Set by `--bind`.
    bind_address: ?[]const u8 = null,
    /// Default upstream-facing interface (see `Upstream.interface`).
    interface: ?[]const u8 = null,
    /// Default upstream request timeout in milliseconds (see
    /// `Upstream.timeout_ms`). Set by `--timeout`.
    timeout_ms: usize = 10000,
    /// Default for skipping TLS certificate verification (see
    /// `Upstream.insecure`). Set by `--insecure`.
    insecure: bool = false,
    upstream: []const Upstream = &.{},
    /// Default value swapped into an upstream's Access-Control-Allow-Origin
    /// response header (set by `--access-control-allow-origin`). `null` means
    /// fall back to `"*"`.
    /// A per-upstream `response_headers` override of that header takes
    /// precedence over this default.
    default_origin: ?[]const u8 = null,
    /// Enable libcurl verbose logging of the upstream HTTP transaction (set by
    /// `--verbose-upstream`). libcurl writes the wire-level details to stderr.
    verbose_upstream: bool = false,

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Replace the upstream list with a single upstream at `host`, using the
    /// catch-all path rule (used by the `--upstream-host` override). The host
    /// string is copied into the arena. Fails with `UpstreamHostConflict` if
    /// the config already defines upstreams.
    pub fn setUpstreamHost(self: *Self, host: []const u8) !void {
        try validateHost(host);
        if (self.upstream.len > 0) return ConfigError.UpstreamHostConflict;
        const a = self.arena.allocator();
        const dup = try a.dupe(u8, host);
        const list = try a.alloc(Upstream, 1);
        list[0] = .{ .host = dup, .path = CatchAllPath[0..1] };
        self.upstream = list;
    }

    /// Load configuration, applying the documented precedence:
    ///   defaults < `file_path` < `json_str` (top-level keys).
    /// `file_path` and/or `json_str` may be null.
    ///
    /// Returns a heap-allocated `*Config` whose storage lives in its internal
    /// arena, so a single `deinit` releases both the struct and every string it
    /// owns. Callers needing a stable pointer (e.g. long-lived proxy state) can
    /// keep the returned pointer without making a second copy.
    pub fn load(io: std.Io, allocator: std.mem.Allocator, file_path: ?[]const u8, json_str: ?[]const u8) !*Self {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const a = arena.allocator();
        const cfg = a.create(Self) catch {
            arena.deinit();
            return error.OutOfMemory;
        };
        cfg.* = .{ .arena = arena };
        errdefer cfg.arena.deinit();

        var from_file = RawConfig{};
        if (file_path) |path| {
            const dir = std.Io.Dir.cwd();
            const text = dir.readFileAlloc(io, path, a, .unlimited) catch |err| {
                if (err == error.FileNotFound) return ConfigError.ConfigFileNotFound;
                return err;
            };
            from_file = try std.json.parseFromSliceLeaky(RawConfig, a, text, .{
                .allocate = .alloc_always,
            });
        }

        var from_str = RawConfig{};
        if (json_str) |s| {
            from_str = try std.json.parseFromSliceLeaky(RawConfig, a, s, .{
                .allocate = .alloc_always,
            });
        }

        cfg.port = from_str.port orelse from_file.port orelse 8080;
        cfg.bind_address = from_str.bind_address orelse from_file.bind_address;
        cfg.interface = from_str.interface orelse from_file.interface;
        cfg.timeout_ms = from_str.timeout_ms orelse from_file.timeout_ms orelse 10000;
        cfg.insecure = from_str.insecure orelse from_file.insecure orelse false;
        cfg.upstream = from_str.upstream orelse from_file.upstream orelse &.{};

        try cfg.validate();
        return cfg;
    }

    pub fn validate(self: *const Self) !void {
        if (self.port == 0) return ConfigError.InvalidPort;

        for (self.upstream) |u| {
            try validateHost(u.host);
            for (u.path) |p| {
                if (!std.mem.eql(u8, p.@"type", "plain")) return ConfigError.InvalidPathType;
                // A blank local (like "/") matches any path, and a blank remote
                // maps to the upstream origin root; both are valid.
            }
            const proto = u.protocol;
            if (!std.mem.eql(u8, proto, "http1") and
                !std.mem.eql(u8, proto, "http2") and
                !std.mem.eql(u8, proto, "auto"))
            {
                return ConfigError.InvalidProtocol;
            }
        }
    }
};

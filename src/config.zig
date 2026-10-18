const std = @import("std");
const pathmap_mod = @import("pathmap");

pub const ConfigError = error{
    InvalidPort,
    MissingHost,
    InvalidHost,
    InvalidPathType,
    /// A "regex" path rule whose `local` is not a valid regular expression.
    InvalidRegex,
    InvalidProtocol,
    UpstreamHostConflict,
    ConfigFileNotFound,
    InvalidConfig,
    /// The overall timeout must be greater than the connect timeout (see
    /// validate). Connect >= overall is meaningless (the connect budget would
    /// already cap the transfer) and makes the timeout-kind heuristic
    /// ambiguous.
    ConnectTimeoutNotLessThanOverall,
};

/// Header overrides for a single direction.
///
/// Decoded from a JSON object whose keys are header names. A value of `null`
/// means "delete this header"; a string value means "set it to this". A header
/// name absent from the object is passed through unchanged.
pub const HeaderOverrides = std.json.ArrayHashMap(?[]const u8);

/// A single path rewrite rule. Re-exported for convenience; the type and its
/// plain/regex implementations live in `pathmap`, which also holds the
/// construction point (`pathmap.buildPathMapping`).
pub const PathMapping = pathmap_mod.PathMapping;

/// JSON-decodable form of a path rule. Decoded by the JSON parser, then built
/// into a runtime `PathMapping` (see `Config.load`), which compiles the pattern
/// for "regex" rules so a malformed regex fails at load time.
const RawPathMapping = struct {
    /// Match type, defaulting to `"plain"` when the key is absent from the JSON
    /// so an omitted type is a valid plain rule.
    @"type": []const u8 = "plain",
    /// The client-facing pattern. Defaults to blank ("") when absent, which
    /// matches any path (the direct/identity case when `remote` is also root).
    local: []const u8 = "",
    remote: []const u8 = "",
};

/// JSON-decodable form of an upstream. Decoded by the JSON parser, then built
/// into a runtime `Upstream` (see `Config.load`).
const RawUpstream = struct {
    host: []const u8,
    interface: ?[]const u8 = null,
    connect_timeout_ms: ?usize = null,
    timeout_ms: ?usize = null,
    insecure: ?bool = null,
    protocol: []const u8 = "auto",
    request_headers: HeaderOverrides = .{ .map = .empty },
    response_headers: HeaderOverrides = .{ .map = .empty },
    path: []RawPathMapping = &.{},
};

/// One upstream server. `host` is the full origin URL (scheme://authority).
pub const Upstream = struct {
    host: []const u8,

    /// Upstream-facing network interface (e.g. "eth0"). `null` means inherit
    /// the top-level default interface.
    interface: ?[]const u8 = null,

    /// Upstream connect timeout in milliseconds (TCP/TLS handshake). `null`
    /// means inherit the top-level default connect timeout
    /// (see `Config.connect_timeout_ms`).
    connect_timeout_ms: ?usize = null,
    /// Upstream overall (total transfer) timeout in milliseconds. `null` means
    /// inherit the top-level default overall timeout (see `Config.timeout_ms`).
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

    /// The effective upstream connect timeout in milliseconds, falling back to
    /// `default` (the top-level default connect timeout).
    pub fn effectiveConnectTimeoutMs(self: *const Upstream, default: usize) usize {
        return self.connect_timeout_ms orelse default;
    }

    /// The effective upstream overall (total transfer) timeout in milliseconds,
    /// falling back to `default` (the top-level default overall timeout).
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
    connect_timeout_ms: ?usize = null,
    insecure: ?bool = null,
    upstream: ?[]RawUpstream = null,
};

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
    /// Default overall (total transfer) upstream timeout in milliseconds (see
    /// `Upstream.timeout_ms`). Set by `--timeout`.
    timeout_ms: usize = 900000,
    /// Default upstream connect timeout in milliseconds (TCP/TLS handshake; see
    /// `Upstream.connect_timeout_ms`). Set by `--connect-timeout`.
    connect_timeout_ms: usize = 10000,
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
        // Release per-rule state (e.g. compiled regex engines) before reclaiming
        // the arena. No-op for arena-built rules (their state lives in the
        // arena), but keeps the deinit correct for non-arena allocators too.
        for (self.upstream) |u| {
            for (u.path) |p| {
                if (p.deinit) |release| release(&p);
            }
        }
        self.arena.deinit();
    }

    /// Replace the upstream list with a single upstream at `host`, using the
    /// catch-all path rule (used by the `--upstream-host` override). The host
    /// string and rule are copied/built into the arena. Fails with
    /// `UpstreamHostConflict` if the config already defines upstreams.
    pub fn setUpstreamHost(self: *Self, host: []const u8) !void {
        try validateHost(host);
        if (self.upstream.len > 0) return ConfigError.UpstreamHostConflict;
        const a = self.arena.allocator();
        const dup = try a.dupe(u8, host);
        // The catch-all rule maps any path to the upstream origin (root).
        const path = try a.alloc(PathMapping, 1);
        errdefer a.free(path);
        path[0] = pathmap_mod.buildPathMapping(a, "plain", "", "") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            pathmap_mod.Error.InvalidPathType => return ConfigError.InvalidPathType,
            pathmap_mod.Error.InvalidRegex => return ConfigError.InvalidRegex,
        };
        const list = try a.alloc(Upstream, 1);
        errdefer a.free(list);
        list[0] = .{ .host = dup, .path = path };
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
        // The arena is copied into cfg above; allocating the rest through the
        // local `a` would append chunks to the local arena's list, leaving
        // cfg.arena a stale snapshot so cfg.arena.deinit() would leak them on
        // an error return. Parse through cfg.arena so its list is complete.
        const ca = cfg.arena.allocator();

        var from_file = RawConfig{};
        if (file_path) |path| {
            const dir = std.Io.Dir.cwd();
            const text = dir.readFileAlloc(io, path, ca, .unlimited) catch |err| {
                if (err == error.FileNotFound) return ConfigError.ConfigFileNotFound;
                return err;
            };
            from_file = try std.json.parseFromSliceLeaky(RawConfig, ca, text, .{
                .allocate = .alloc_always,
            });
        }

        var from_str = RawConfig{};
        if (json_str) |s| {
            from_str = try std.json.parseFromSliceLeaky(RawConfig, ca, s, .{
                .allocate = .alloc_always,
            });
        }

        cfg.port = from_str.port orelse from_file.port orelse 8080;
        cfg.bind_address = from_str.bind_address orelse from_file.bind_address;
        cfg.interface = from_str.interface orelse from_file.interface;
        cfg.timeout_ms = from_str.timeout_ms orelse from_file.timeout_ms orelse 900000;
        cfg.connect_timeout_ms = from_str.connect_timeout_ms orelse from_file.connect_timeout_ms orelse 10000;
        cfg.insecure = from_str.insecure orelse from_file.insecure orelse false;

        const raw_upstream = from_str.upstream orelse from_file.upstream orelse &.{};
        cfg.upstream = try Self.buildUpstreams(ca, raw_upstream);

        try cfg.validate();
        return cfg;
    }

    /// Build the runtime upstream list from the decoded (raw) upstreams,
    /// constructing each path rule via `pathmap.buildPathMapping` (which
    /// compiles regex patterns and rejects unknown types).
    fn buildUpstreams(allocator: std.mem.Allocator, raw: []const RawUpstream) ![]Upstream {
        const list = try allocator.alloc(Upstream, raw.len);
        errdefer allocator.free(list);
        for (raw, list) |r, *u| {
            const path = try Self.buildPaths(allocator, r.path);
            errdefer allocator.free(path);
            u.* = Upstream{
                .host = r.host,
                .interface = r.interface,
                .connect_timeout_ms = r.connect_timeout_ms,
                .timeout_ms = r.timeout_ms,
                .insecure = r.insecure,
                .protocol = r.protocol,
                .request_headers = r.request_headers,
                .response_headers = r.response_headers,
                .path = path,
            };
        }
        return list;
    }

    /// Build the runtime path rules from the decoded (raw) rules, mapping the
    /// pathmap construction errors onto the config error set.
    fn buildPaths(allocator: std.mem.Allocator, raw: []const RawPathMapping) ![]PathMapping {
        const list = try allocator.alloc(PathMapping, raw.len);
        errdefer allocator.free(list);
        for (raw, list) |r, *u| {
            u.* = pathmap_mod.buildPathMapping(allocator, r.@"type", r.local, r.remote) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                pathmap_mod.Error.InvalidPathType => return ConfigError.InvalidPathType,
                pathmap_mod.Error.InvalidRegex => return ConfigError.InvalidRegex,
            };
        }
        return list;
    }

    pub fn validate(self: *const Self) !void {
        if (self.port == 0) return ConfigError.InvalidPort;

        // The overall (total transfer) timeout must exceed the connect timeout.
        // Checked at the top level (covers the catch-all upstream added by
        // --upstream-host, which inherits these defaults) and per-upstream for
        // the resolved effective values.
        if (self.timeout_ms <= self.connect_timeout_ms) return ConfigError.ConnectTimeoutNotLessThanOverall;

        for (self.upstream) |u| {
            try validateHost(u.host);
            if (u.effectiveTimeoutMs(self.timeout_ms) <= u.effectiveConnectTimeoutMs(self.connect_timeout_ms)) {
                return ConfigError.ConnectTimeoutNotLessThanOverall;
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

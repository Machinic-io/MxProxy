const std = @import("std");
const httpx = @import("httpx");
const curl = @import("curl");
const config_mod = @import("config");
const router_mod = @import("router");
const headers_mod = @import("headers");
const forward_mod = @import("forward");
const server_mod = @import("server");

const log = std.log.scoped(.main);

pub const MainError = error{
    InvalidPort,
    InvalidTimeout,
    BadArgument,
};

/// Set from the command line (--silent) before serving starts; request threads
/// only read it. While true, the log function below drops info/debug messages
/// so only warning/error-level output is printed.
var silent: bool = false;

/// Root-level log override (see `std_options`): forwards every message to the
/// standard default logger, except info/debug messages while `--silent` is on.
/// 0.17's log levels are a comptime filter, so a runtime switch like --silent
/// has to live here, in the log function itself.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (silent and (level == .info or level == .debug)) return;
    std.log.defaultLog(level, scope, format, args);
}

pub const std_options: std.Options = .{ .logFn = logFn };

const USAGE =
    "Usage: mxproxy [OPTIONS]\n" ++
    "\n" ++
    "Options:\n" ++
    "  --config=<path>                            Path to a JSON config file\n" ++
    "  --config-json=<json>                       Inline JSON config (top-level keys)\n" ++
    "  --port=<port>                              Listen port (default: 8080)\n" ++
    "  --bind=<ip>                                Listen address (default: all interfaces)\n" ++
    "  --timeout=<ms>                             Default overall upstream timeout (default: 900000)\n" ++
    "  --connect-timeout=<ms>                     Upstream connect timeout (default: 10000)\n" ++
    "  --insecure                                 Skip upstream TLS certificate verification\n" ++
    "  --upstream-host=<url>                      Single upstream origin (catch-all path rule)\n" ++
    "  --access-control-allow-origin=<origin>     Default CORS origin (default: \"*\")\n" ++
    "  --interface=<if>                           Default upstream-facing interface\n" ++
    "  --verbose, -v                              Verbose logging\n" ++
    "  --verbose-upstream                         Verbose libcurl upstream logging\n" ++
    "  --silent                                   Hide info-level log messages\n" ++
    "  --help, -h                                 Show this help\n";

fn valueAfter(arg: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, arg, '=')) |eq| return arg[eq + 1 ..];
    return "";
}

/// A user-actionable explanation for the config errors the proxy can raise at
/// startup. Returns null for errors without a dedicated sentence (e.g. OOM or a
/// malformed-JSON parse error), whose bare name is still informative.
fn configErrorDetail(err: anyerror) ?[]const u8 {
    return switch (err) {
        config_mod.ConfigError.InvalidPort => "port must be non-zero",
        config_mod.ConfigError.MissingHost => "an upstream is missing its host",
        config_mod.ConfigError.InvalidHost => "an upstream host is not a full 'scheme://authority' URL (missing '://')",
        config_mod.ConfigError.InvalidPathType => "a path rule uses an unsupported type (supported: plain, regex)",
        config_mod.ConfigError.InvalidRegex => "a path rule's 'local' is not a valid regular expression",
        config_mod.ConfigError.InvalidProtocol => "an upstream protocol must be 'http1', 'http2', or 'auto'",
        config_mod.ConfigError.UpstreamHostConflict => "--upstream-host conflicts with upstreams already configured",
        config_mod.ConfigError.ConfigFileNotFound => "config file not found",
        config_mod.ConfigError.InvalidConfig => "invalid config",
        config_mod.ConfigError.ConnectTimeoutNotLessThanOverall => "overall timeout must be greater than the connect timeout",
        else => null,
    };
}

fn logConfigError(err: anyerror) void {
    if (configErrorDetail(err)) |detail| log.err("config error: {s}", .{detail}) else log.err("config error: {any}", .{err});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // The page allocator frees individual allocations (unlike the process
    // arena, whose free is a no-op), so per-request state allocated through it
    // is returned to the OS as requests complete instead of accumulating.
    const allocator = std.heap.page_allocator;

    // Collect command-line arguments, skipping the executable name.
    var arg_it = init.minimal.args.iterate();
    defer arg_it.deinit();
    _ = arg_it.skip();
    var args = std.array_list.Managed([]const u8).init(allocator);
    defer args.deinit();
    while (arg_it.next()) |arg| try args.append(arg);

    var config_file: ?[]const u8 = null;
    var config_json: ?[]const u8 = null;
    var port_override: ?u16 = null;
    var bind_override: ?[]const u8 = null;
    var timeout_override: ?usize = null;
    var connect_timeout_override: ?usize = null;
    var insecure_override = false;
    var upstream_host_override: ?[]const u8 = null;
    var origin_override: ?[]const u8 = null;
    var verbose = false;
    var verbose_upstream = false;
    var interface_override: ?[]const u8 = null;

    for (args.items) |arg| {
        if (std.mem.startsWith(u8, arg, "--config=")) {
            config_file = arg["--config=".len..];
        } else if (std.mem.startsWith(u8, arg, "--config-json=")) {
            config_json = arg["--config-json=".len..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            port_override = std.fmt.parseInt(u16, valueAfter(arg), 10) catch return MainError.InvalidPort;
        } else if (std.mem.startsWith(u8, arg, "--bind=")) {
            const value = valueAfter(arg);
            bind_override = if (value.len > 0) value else null;
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_override = std.fmt.parseInt(usize, valueAfter(arg), 10) catch return MainError.InvalidTimeout;
        } else if (std.mem.startsWith(u8, arg, "--connect-timeout=")) {
            connect_timeout_override = std.fmt.parseInt(usize, valueAfter(arg), 10) catch return MainError.InvalidTimeout;
        } else if (std.mem.startsWith(u8, arg, "--upstream-host=")) {
            upstream_host_override = valueAfter(arg);
        } else if (std.mem.startsWith(u8, arg, "--access-control-allow-origin=")) {
            const value = valueAfter(arg);
            origin_override = if (value.len > 0) value else null;
        } else if (std.mem.startsWith(u8, arg, "--interface=")) {
            const value = valueAfter(arg);
            interface_override = if (value.len > 0) value else null;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--verbose-upstream")) {
            verbose_upstream = true;
        } else if (std.mem.eql(u8, arg, "--insecure")) {
            insecure_override = true;
        } else if (std.mem.eql(u8, arg, "--silent")) {
            silent = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{USAGE});
            return;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return MainError.BadArgument;
        }
    }

    const config = config_mod.Config.load(io, allocator, config_file, config_json) catch |err| {
        logConfigError(err);
        return err;
    };

    // Explicit CLI overrides take precedence over the config sources.
    if (port_override) |p| config.port = p;
    if (bind_override) |b| config.bind_address = b;
    if (timeout_override) |t| config.timeout_ms = t;
    if (connect_timeout_override) |t| config.connect_timeout_ms = t;
    if (insecure_override) config.insecure = true;
    if (upstream_host_override) |h| {
        config.setUpstreamHost(h) catch |err| {
            logConfigError(err);
            return err;
        };
    }
    if (origin_override) |o| config.default_origin = o;
    if (interface_override) |i| config.interface = i;
    if (verbose_upstream) config.verbose_upstream = true;

    // The overrides above are applied AFTER Config.load's own validation, so
    // re-validate the resolved values (e.g. --port=0 must still be rejected,
    // and --timeout/--connect-timeout can violate the ordering check).
    config.validate() catch |err| {
        logConfigError(err);
        return err;
    };

    // The config is process-lifetime: it is allocated from `allocator` and
    // never freed (reclaimed at exit), so in-flight request threads keep valid
    // references. Per-request allocations also use `allocator` but are freed
    // on every request, so the working set stays bounded to in-flight requests
    // rather than growing without bound.
    try curl.globalInit();
    defer curl.globalDeinit();

    if (verbose) {
        log.info("verbose logging enabled", .{});
        log.info("bind {s}", .{if (config.bind_address) |b| b else "0.0.0.0 (default)"});
        log.info("interface {s}", .{if (config.interface) |i| i else "(default)"});
        log.info("default overall timeout {d}ms", .{config.timeout_ms});
        log.info("default connect timeout {d}ms", .{config.connect_timeout_ms});
        log.info("insecure {s}", .{if (config.insecure) "enabled" else "disabled"});
        log.info("default origin override {s}", .{if (config.default_origin) |o| o else "* (fallback)"});
        log.info("verbose upstream {s}", .{if (config.verbose_upstream) "enabled" else "disabled"});
        for (config.upstream) |u| {
            log.info("  upstream {s} (overall timeout {d}ms, connect timeout {d}ms, insecure {s}, {d} path rule(s))", .{ u.host, u.effectiveTimeoutMs(config.timeout_ms), u.effectiveConnectTimeoutMs(config.connect_timeout_ms), if (u.effectiveInsecure(config.insecure)) "enabled" else "disabled", u.path.len });
        }
    }

    // Stack-local: main's frame lives for the whole process, so request
    // threads keep a valid reference until run() returns.
    var forwarder = try forward_mod.Forwarder.init(config, verbose, silent);

    var server = server_mod.Server.init(&forwarder, allocator, io);
    server.registerSignalHandlers();
    defer server.deregisterSignalHandlers();

    // run() already logs any specific failure, so just propagate the error.
    server.run() catch |err| {
        return err;
    };
}

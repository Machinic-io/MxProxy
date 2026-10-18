const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config");
const Config = config_mod.Config;
const router_mod = @import("router");
const headers_mod = @import("headers");
const forward_mod = @import("forward");
const httpx = @import("httpx");
const tcp = httpx.tcp;
const parser = httpx.http1.parser;

// NOTE: the pinned Zig 0.17 toolchain does not accept backtick multiline string
// literals, so all JSON fixtures here use regular double-quoted strings.

test "config: defaults" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    var cfg = try Config.load(io_ctx.io, allocator, null, null);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expect(cfg.bind_address == null);
    try std.testing.expect(cfg.interface == null);
    try std.testing.expectEqual(@as(usize, 900000), cfg.timeout_ms);
    try std.testing.expectEqual(@as(usize, 10000), cfg.connect_timeout_ms);
    try std.testing.expectEqual(@as(usize, 0), cfg.upstream.len);
}

test "config: bind_address from json" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    const json = "{\"port\": 9090, \"bind_address\": \"127.0.0.1\", \"upstream\": [{\"host\": \"https://example.com\"}]}";
    var cfg = try Config.load(io_ctx.io, allocator, null, json);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 9090), cfg.port);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.bind_address.?);
}

test "config: decode full config from json string" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    const json = "{\"port\": 9090, \"interface\": \"lo\", \"upstream\": [" ++
        "{\"host\": \"https://example.com\", \"interface\": \"eth0\", " ++
        "\"timeout_ms\": 4321, \"connect_timeout_ms\": 1234, \"insecure\": true, " ++
        "\"request_headers\": {\"Origin\": null, \"X-Forwarded-For\": \"1.2.3.4\"}, " ++
        "\"response_headers\": {\"Server\": null}, " ++
        "\"path\": [{\"type\": \"plain\", \"local\": \"/example/\", \"remote\": \"/\"}, " ++
        "{\"type\": \"plain\", \"local\": \"/other/\", \"remote\": \"/base/\"}]}]}";

    var cfg = try Config.load(io_ctx.io, allocator, null, json);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 9090), cfg.port);
    try std.testing.expectEqualStrings("lo", cfg.interface.?);
    try std.testing.expectEqual(@as(usize, 1), cfg.upstream.len);

    const u = cfg.upstream[0];
    try std.testing.expectEqualStrings("https://example.com", u.host);
    try std.testing.expectEqualStrings("eth0", u.interface.?);
    try std.testing.expectEqual(@as(usize, 4321), u.timeout_ms.?);
    // effective overall timeout: per-upstream wins over the default
    try std.testing.expectEqual(@as(usize, 4321), u.effectiveTimeoutMs(900000));
    try std.testing.expectEqual(@as(usize, 1234), u.connect_timeout_ms.?);
    // effective connect timeout: per-upstream wins over the default
    try std.testing.expectEqual(@as(usize, 1234), u.effectiveConnectTimeoutMs(10000));
    try std.testing.expect(u.insecure.?);
    // effective insecure: per-upstream wins over the default
    try std.testing.expect(u.effectiveInsecure(false));
    // effective interface: per-upstream wins over default
    try std.testing.expectEqualStrings("eth0", u.effectiveInterface("lo").?);

    // request headers: present-with-null (delete) and present-with-value (set)
    try std.testing.expect(u.request_headers.map.get("Origin") != null);
    if (u.request_headers.map.get("Origin")) |v| {
        try std.testing.expect(v == null);
    }
    if (u.request_headers.map.get("X-Forwarded-For")) |v| {
        try std.testing.expectEqualStrings("1.2.3.4", v.?);
    } else {
        unreachable;
    }
    // absent key stays absent
    try std.testing.expect(u.request_headers.map.get("Host") == null);

    // response headers: delete Server
    if (u.response_headers.map.get("Server")) |v| {
        try std.testing.expect(v == null);
    } else {
        unreachable;
    }

    // path mappings
    try std.testing.expectEqual(@as(usize, 2), u.path.len);
    try std.testing.expectEqualStrings("plain", u.path[0].type);
    try std.testing.expectEqualStrings("/example/", u.path[0].local);
    try std.testing.expectEqualStrings("/", u.path[0].remote);
    try std.testing.expectEqualStrings("/other/", u.path[1].local);
    try std.testing.expectEqualStrings("/base/", u.path[1].remote);
}

test "config: path mapping type defaults to plain when missing" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    // A path rule with no `type` key decodes to the "plain" default, so
    // Config.load's validation passes; an explicit type is honored as-is.
    const json = "{\"upstream\": [{\"host\": \"https://example.com\", \"path\": [{\"local\": \"/a/\", \"remote\": \"/b/\"}, {\"type\": \"plain\", \"local\": \"/c/\"}]}]}";

    var cfg = try Config.load(io_ctx.io, allocator, null, json);
    defer cfg.deinit();

    const u = cfg.upstream[0];
    try std.testing.expectEqual(@as(usize, 2), u.path.len);
    // missing type defaults to "plain"
    try std.testing.expectEqualStrings("plain", u.path[0].type);
    try std.testing.expectEqualStrings("/a/", u.path[0].local);
    try std.testing.expectEqualStrings("/b/", u.path[0].remote);
    // explicit type is honored, and missing remote defaults to ""
    try std.testing.expectEqualStrings("plain", u.path[1].type);
    try std.testing.expectEqualStrings("/c/", u.path[1].local);
    try std.testing.expectEqualStrings("", u.path[1].remote);
}

test "config: upstream interface fallback to default" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    const json = "{\"interface\": \"default-iface\", \"upstream\": [" ++
        "{\"host\": \"https://a.example.com\", \"interface\": \"override-iface\"}, " ++
        "{\"host\": \"https://b.example.com\"}]}";

    var cfg = try Config.load(io_ctx.io, allocator, null, json);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("override-iface", cfg.upstream[0].effectiveInterface(cfg.interface).?);
    try std.testing.expectEqualStrings("default-iface", cfg.upstream[1].effectiveInterface(cfg.interface).?);
    // with no default at all
    try std.testing.expectEqualStrings("override-iface", cfg.upstream[0].effectiveInterface(null).?);
    try std.testing.expect(cfg.upstream[1].effectiveInterface(null) == null);
}

test "config: connect timeout default + effective fallback" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    // No top-level connect timeout: default is 10s, a per-upstream
    // connect_timeout_ms still wins.
    const json_default = "{\"upstream\": [" ++
        "{\"host\": \"https://a.example.com\", \"connect_timeout_ms\": 4321}, " ++
        "{\"host\": \"https://b.example.com\"}]}";
    var cfg1 = try Config.load(io_ctx.io, allocator, null, json_default);
    defer cfg1.deinit();
    try std.testing.expectEqual(@as(usize, 10000), cfg1.connect_timeout_ms);
    try std.testing.expectEqual(@as(usize, 4321), cfg1.upstream[0].effectiveConnectTimeoutMs(cfg1.connect_timeout_ms));
    try std.testing.expectEqual(@as(usize, 10000), cfg1.upstream[1].effectiveConnectTimeoutMs(cfg1.connect_timeout_ms));

    // A top-level connect_timeout_ms overrides the built-in default for upstreams
    // that do not set their own.
    const json_custom = "{\"connect_timeout_ms\": 20000, \"upstream\": [" ++
        "{\"host\": \"https://a.example.com\"}, " ++
        "{\"host\": \"https://b.example.com\", \"connect_timeout_ms\": 777}]}";
    var cfg2 = try Config.load(io_ctx.io, allocator, null, json_custom);
    defer cfg2.deinit();
    try std.testing.expectEqual(@as(usize, 20000), cfg2.connect_timeout_ms);
    try std.testing.expectEqual(@as(usize, 20000), cfg2.upstream[0].effectiveConnectTimeoutMs(cfg2.connect_timeout_ms));
    try std.testing.expectEqual(@as(usize, 777), cfg2.upstream[1].effectiveConnectTimeoutMs(cfg2.connect_timeout_ms));
}

test "config: overall timeout default + effective fallback" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    // No top-level overall timeout: default is 900000ms, a per-upstream
    // timeout_ms still wins.
    const json_default = "{\"upstream\": [" ++
        "{\"host\": \"https://a.example.com\", \"timeout_ms\": 43210}, " ++
        "{\"host\": \"https://b.example.com\"}]}";
    var cfg1 = try Config.load(io_ctx.io, allocator, null, json_default);
    defer cfg1.deinit();
    try std.testing.expectEqual(@as(usize, 900000), cfg1.timeout_ms);
    try std.testing.expectEqual(@as(usize, 43210), cfg1.upstream[0].effectiveTimeoutMs(cfg1.timeout_ms));
    try std.testing.expectEqual(@as(usize, 900000), cfg1.upstream[1].effectiveTimeoutMs(cfg1.timeout_ms));

    // A top-level timeout_ms overrides the built-in default for upstreams that
    // do not set their own.
    const json_custom = "{\"timeout_ms\": 20000, \"upstream\": [" ++
        "{\"host\": \"https://a.example.com\"}, " ++
        "{\"host\": \"https://b.example.com\", \"timeout_ms\": 77700}]}";
    var cfg2 = try Config.load(io_ctx.io, allocator, null, json_custom);
    defer cfg2.deinit();
    try std.testing.expectEqual(@as(usize, 20000), cfg2.timeout_ms);
    try std.testing.expectEqual(@as(usize, 20000), cfg2.upstream[0].effectiveTimeoutMs(cfg2.timeout_ms));
    try std.testing.expectEqual(@as(usize, 77700), cfg2.upstream[1].effectiveTimeoutMs(cfg2.timeout_ms));
}

test "config: timeout validation accepts connect < overall" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    // Defaults are valid (overall 900000 > connect 10000).
    var cfg0 = try Config.load(io_ctx.io, allocator, null, "{\"upstream\": [{\"host\": \"https://a.example.com\"}]}");
    defer cfg0.deinit();
    try std.testing.expect(cfg0.upstream[0].effectiveTimeoutMs(cfg0.timeout_ms) > cfg0.upstream[0].effectiveConnectTimeoutMs(cfg0.connect_timeout_ms));

    // Per-upstream overrides keep the effective connect below the overall.
    const json = "{\"timeout_ms\": 10000, \"connect_timeout_ms\": 1000, \"upstream\": [" ++
        "{\"host\": \"https://a.example.com\", \"connect_timeout_ms\": 2000}, " ++
        "{\"host\": \"https://b.example.com\", \"timeout_ms\": 30000, \"connect_timeout_ms\": 5000}]}";
    var cfg = try Config.load(io_ctx.io, allocator, null, json);
    defer cfg.deinit();
    for (cfg.upstream) |u| {
        try std.testing.expect(u.effectiveTimeoutMs(cfg.timeout_ms) > u.effectiveConnectTimeoutMs(cfg.connect_timeout_ms));
    }
}

test "forward: classifyTimeout heuristic" {
    const connect = @as(u64, 10000);
    const overall = @as(u64, 900000);

    // A connect timeout ends at ~connect_ms, far below the midpoint (~455000ms).
    try std.testing.expectEqual(@as(forward_mod.TimeoutKind, .connect), forward_mod.classifyTimeout(10000, connect, overall));
    try std.testing.expectEqual(@as(forward_mod.TimeoutKind, .connect), forward_mod.classifyTimeout(11000, connect, overall));
    // An overall timeout ends at ~overall_ms, above the midpoint.
    try std.testing.expectEqual(@as(forward_mod.TimeoutKind, .overall), forward_mod.classifyTimeout(900000, connect, overall));
    try std.testing.expectEqual(@as(forward_mod.TimeoutKind, .overall), forward_mod.classifyTimeout(899000, connect, overall));
    // The boundary is the midpoint: (10000 + 900000) / 2 = 455000ms.
    try std.testing.expectEqual(@as(forward_mod.TimeoutKind, .connect), forward_mod.classifyTimeout(455000, connect, overall));
    try std.testing.expectEqual(@as(forward_mod.TimeoutKind, .overall), forward_mod.classifyTimeout(455001, connect, overall));
}

test "config: insecure default + effective fallback" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    // No top-level insecure: default is false, a per-upstream insecure still wins.
    const json_default = "{\"upstream\": [" ++
        "{\"host\": \"https://a.example.com\", \"insecure\": true}, " ++
        "{\"host\": \"https://b.example.com\"}]}";
    var cfg1 = try Config.load(io_ctx.io, allocator, null, json_default);
    defer cfg1.deinit();
    try std.testing.expect(!cfg1.insecure);
    try std.testing.expect(cfg1.upstream[0].effectiveInsecure(cfg1.insecure));
    try std.testing.expect(!cfg1.upstream[1].effectiveInsecure(cfg1.insecure));

    // A top-level insecure overrides the built-in default for upstreams that do
    // not set their own (a per-upstream false still wins over the default).
    const json_custom = "{\"insecure\": true, \"upstream\": [" ++
        "{\"host\": \"https://a.example.com\"}, " ++
        "{\"host\": \"https://b.example.com\", \"insecure\": false}]}";
    var cfg2 = try Config.load(io_ctx.io, allocator, null, json_custom);
    defer cfg2.deinit();
    try std.testing.expect(cfg2.insecure);
    try std.testing.expect(cfg2.upstream[0].effectiveInsecure(cfg2.insecure));
    try std.testing.expect(!cfg2.upstream[1].effectiveInsecure(cfg2.insecure));
}

test "config: file < string top-level precedence" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io;
    const dir = std.Io.Dir.cwd();
    const path = "mxproxy_cfg_precedence_test.json";
    defer dir.deleteFile(io, path) catch {};

    const file_json = "{\"port\": 1111, \"interface\": \"file-iface\", \"upstream\": [{\"host\": \"https://file.example.com\"}]}";
    try dir.writeFile(io, .{ .sub_path = path, .data = file_json, .flags = .{} });

    const str_json = "{\"port\": 2222, \"upstream\": [{\"host\": \"https://str.example.com\"}]}";

    var cfg = try Config.load(io, allocator, path, str_json);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 2222), cfg.port); // string wins
    try std.testing.expectEqualStrings("file-iface", cfg.interface.?); // file (absent in string)
    try std.testing.expectEqual(@as(usize, 1), cfg.upstream.len);
    try std.testing.expectEqualStrings("https://str.example.com", cfg.upstream[0].host); // string wins
}

test "config: file only (no string override)" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io;
    const dir = std.Io.Dir.cwd();
    const path = "mxproxy_cfg_fileonly_test.json";
    defer dir.deleteFile(io, path) catch {};

    const file_json = "{\"port\": 3333, \"interface\": \"lo\", \"upstream\": [{\"host\": \"https://file.example.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/x/\", \"remote\": \"/\"}]}]}";
    try dir.writeFile(io, .{ .sub_path = path, .data = file_json, .flags = .{} });

    var cfg = try Config.load(io, allocator, path, null);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 3333), cfg.port);
    try std.testing.expectEqualStrings("lo", cfg.interface.?);
    try std.testing.expectEqual(@as(usize, 1), cfg.upstream.len);
    try std.testing.expectEqualStrings("https://file.example.com", cfg.upstream[0].host);
    try std.testing.expectEqual(@as(usize, 1), cfg.upstream[0].path.len);
}

test "config: missing file is an error" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    try std.testing.expectError(
        config_mod.ConfigError.ConfigFileNotFound,
        Config.load(io_ctx.io, allocator, "/nonexistent/mxproxy/does_not_exist.json", null),
    );
}

test "config: validation errors" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    // host without scheme
    try std.testing.expectError(
        config_mod.ConfigError.InvalidHost,
        Config.load(io_ctx.io, allocator, null, "{\"upstream\": [{\"host\": \"example.com\"}]}"),
    );
    // empty host
    try std.testing.expectError(
        config_mod.ConfigError.MissingHost,
        Config.load(io_ctx.io, allocator, null, "{\"upstream\": [{\"host\": \"\"}]}"),
    );
    // unknown path type
    try std.testing.expectError(
        config_mod.ConfigError.InvalidPathType,
        Config.load(io_ctx.io, allocator, null, "{\"upstream\": [{\"host\": \"https://x.com\", \"path\": [{\"type\": \"fancy\", \"local\": \"/a\", \"remote\": \"/b\"}]}]}"),
    );
    // a "regex" rule whose local does not compile to a valid regular expression
    // (unbalanced parenthesis) is rejected at load time
    try std.testing.expectError(
        config_mod.ConfigError.InvalidRegex,
        Config.load(io_ctx.io, allocator, null, "{\"upstream\": [{\"host\": \"https://x.com\", \"path\": [{\"type\": \"regex\", \"local\": \"([0-9+\", \"remote\": \"/b\"}]}]}"),
    );
    // port 0
    try std.testing.expectError(
        config_mod.ConfigError.InvalidPort,
        Config.load(io_ctx.io, allocator, null, "{\"port\": 0}"),
    );
    // unknown protocol
    try std.testing.expectError(
        config_mod.ConfigError.InvalidProtocol,
        Config.load(io_ctx.io, allocator, null, "{\"upstream\": [{\"host\": \"https://x.com\", \"protocol\": \"http3\"}]}"),
    );
    // top-level overall timeout less than the connect timeout
    try std.testing.expectError(
        config_mod.ConfigError.ConnectTimeoutNotLessThanOverall,
        Config.load(io_ctx.io, allocator, null, "{\"timeout_ms\": 1000, \"connect_timeout_ms\": 2000, \"upstream\": [{\"host\": \"https://x.com\"}]}"),
    );
    // top-level overall timeout equal to the connect timeout
    try std.testing.expectError(
        config_mod.ConfigError.ConnectTimeoutNotLessThanOverall,
        Config.load(io_ctx.io, allocator, null, "{\"timeout_ms\": 5000, \"connect_timeout_ms\": 5000, \"upstream\": [{\"host\": \"https://x.com\"}]}"),
    );
    // per-upstream connect override that exceeds the effective overall timeout
    try std.testing.expectError(
        config_mod.ConfigError.ConnectTimeoutNotLessThanOverall,
        Config.load(io_ctx.io, allocator, null, "{\"timeout_ms\": 10000, \"connect_timeout_ms\": 1000, \"upstream\": [{\"host\": \"https://x.com\", \"connect_timeout_ms\": 20000}]}"),
    );
}

test "config: protocol field" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    // default is "auto"
    var cfg = try Config.load(io_ctx.io, allocator, null, "{\"upstream\": [{\"host\": \"https://x.com\"}]}");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("auto", cfg.upstream[0].protocol);

    // explicit values are preserved
    var c1 = try Config.load(io_ctx.io, allocator, null, "{\"upstream\": [{\"host\": \"https://x.com\", \"protocol\": \"http1\"}]}");
    defer c1.deinit();
    try std.testing.expectEqualStrings("http1", c1.upstream[0].protocol);
    var c2 = try Config.load(io_ctx.io, allocator, null, "{\"upstream\": [{\"host\": \"https://x.com\", \"protocol\": \"http2\"}]}");
    defer c2.deinit();
    try std.testing.expectEqualStrings("http2", c2.upstream[0].protocol);
}

test "config: setUpstreamHost" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    var cfg = try Config.load(io_ctx.io, allocator, null, null);
    defer cfg.deinit();
    try cfg.setUpstreamHost("http://localhost:9931");
    try std.testing.expectEqual(@as(usize, 1), cfg.upstream.len);
    try std.testing.expectEqualStrings("http://localhost:9931", cfg.upstream[0].host);
    try std.testing.expectEqual(@as(usize, 1), cfg.upstream[0].path.len);
    try std.testing.expectEqualStrings("plain", cfg.upstream[0].path[0].type);
    try std.testing.expectEqualStrings("", cfg.upstream[0].path[0].local);
    try std.testing.expectEqualStrings("", cfg.upstream[0].path[0].remote);
}

test "config: setUpstreamHost conflict" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    // A config that already defines upstreams must reject --upstream-host.
    var cfg = try Config.load(io_ctx.io, allocator, null, "{\"upstream\": [{\"host\": \"https://x.com\"}]}");
    defer cfg.deinit();
    try std.testing.expectError(
        config_mod.ConfigError.UpstreamHostConflict,
        cfg.setUpstreamHost("http://localhost:9931"),
    );
}

test "config: setUpstreamHost rejects a malformed host" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    var cfg = try Config.load(io_ctx.io, allocator, null, null);
    defer cfg.deinit();
    // Missing the "//" after the scheme — the exact typo that previously slipped
    // past startup and made libcurl fail per-request with CURLE_URL_MALFORMAT.
    try std.testing.expectError(
        config_mod.ConfigError.InvalidHost,
        cfg.setUpstreamHost("https:www.google.com"),
    );
}

fn loadConfig(allocator: Allocator, io_ctx: *httpx.IoContext, json: []const u8) !*Config {
    return Config.load(io_ctx.io, allocator, null, json);
}

test "router: prefix rewrite" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/example/\", \"remote\": \"/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const route = try router.resolve(allocator, "/example/foo/bar") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("https://e.com", route.upstream.host);
    try std.testing.expectEqualStrings("/foo/bar", route.remote_path);
}

test "router: rewrite to a different prefix" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/a/\", \"remote\": \"/b/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const route = try router.resolve(allocator, "/a/x") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("/b/x", route.remote_path);
}

test "router: first match wins across upstreams" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [" ++
        "{\"host\": \"https://first.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/x/\", \"remote\": \"/1/\"}]}, " ++
        "{\"host\": \"https://second.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/x/\", \"remote\": \"/2/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const route = try router.resolve(allocator, "/x/y") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("https://first.com", route.upstream.host);
    try std.testing.expectEqualStrings("/1/y", route.remote_path);
}

test "router: catch-all passthrough when no rule matches" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [" ++
        "{\"host\": \"https://specific.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/api/\", \"remote\": \"/\"}]}, " ++
        "{\"host\": \"https://default.com\"}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    // non-matching path falls through to the rule-less catch-all upstream
    const route = try router.resolve(allocator, "/other/thing") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("https://default.com", route.upstream.host);
    try std.testing.expectEqualStrings("/other/thing", route.remote_path);
}

test "router: no match and no catch-all returns null" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://s.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/api/\", \"remote\": \"/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    try std.testing.expect((try router.resolve(allocator, "/nope")) == null);
}

test "router: root prefix matches everything" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://s.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/\", \"remote\": \"/base/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const route = try router.resolve(allocator, "/anything/at/all") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("/base/anything/at/all", route.remote_path);
}

test "router: first rule wins within a single upstream" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [" ++
        "{\"type\": \"plain\", \"local\": \"/a/\", \"remote\": \"/1/\"}, " ++
        "{\"type\": \"plain\", \"local\": \"/a/b/\", \"remote\": \"/2/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    // Both rules prefix-match /a/b/x, but the first-listed rule wins.
    const route = try router.resolve(allocator, "/a/b/x") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("/1/b/x", route.remote_path);
}

test "router: later rule matches when earlier does not" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [" ++
        "{\"type\": \"plain\", \"local\": \"/a/\", \"remote\": \"/1/\"}, " ++
        "{\"type\": \"plain\", \"local\": \"/b/\", \"remote\": \"/2/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const route = try router.resolve(allocator, "/b/x") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("/2/x", route.remote_path);
}

test "router: prefix match is literal, not segment-aware" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/api/\", \"remote\": \"/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    // "/apifoo" and "/api" do not start with the literal "/api/" prefix, so
    // with no catch-all upstream they must not match at all.
    try std.testing.expect((try router.resolve(allocator, "/apifoo")) == null);
    try std.testing.expect((try router.resolve(allocator, "/api")) == null);
}

test "router: matching exactly the prefix yields empty rest" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/api/\", \"remote\": \"/base/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const route = try router.resolve(allocator, "/api/") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("/base", route.remote_path);
}

test "router: a rule match beats the catch-all" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [" ++
        "{\"host\": \"https://default.com\"}, " ++
        "{\"host\": \"https://specific.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/x/\", \"remote\": \"/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    // The rule-less upstream sits first, but a matching rule elsewhere wins.
    const hit = try router.resolve(allocator, "/x/y") orelse return error.NoRoute;
    defer hit.deinit();
    try std.testing.expectEqualStrings("https://specific.com", hit.upstream.host);
    try std.testing.expectEqualStrings("/y", hit.remote_path);
    // Only when no rule matches does the catch-all apply.
    const fall = try router.resolve(allocator, "/other") orelse return error.NoRoute;
    defer fall.deinit();
    try std.testing.expectEqualStrings("https://default.com", fall.upstream.host);
    try std.testing.expectEqualStrings("/other", fall.remote_path);
}

test "router: catch-all picks the first rule-less upstream" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [" ++
        "{\"host\": \"https://d1.com\"}, " ++
        "{\"host\": \"https://d2.com\"}, " ++
        "{\"host\": \"https://s.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/z/\", \"remote\": \"/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    // Two rule-less upstreams: the first one is the catch-all.
    const route = try router.resolve(allocator, "/anything") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("https://d1.com", route.upstream.host);
    try std.testing.expectEqualStrings("/anything", route.remote_path);
}

test "router: plain and regex rules dispatch by type" {
    const allocator = std.testing.allocator;
    // One upstream with a plain rule and a regex rule: the first matching rule
    // wins, and each rule dispatches to its own implementation via the vtable.
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [" ++
        "{\"type\": \"plain\", \"local\": \"/a/\", \"remote\": \"/p/\"}, " ++
        "{\"type\": \"regex\", \"local\": \"/r/([0-9]+)\", \"remote\": \"/p/$1\"}]}]}");
    defer cfg.deinit();
    const router = router_mod.Router.init(cfg.upstream);
    // The plain rule matches /a/x first.
    const hit = try router.resolve(allocator, "/a/x") orelse return error.NoRoute;
    defer hit.deinit();
    try std.testing.expectEqualStrings("/p/x", hit.remote_path);
    // The regex rule matches /r/123 (the plain /a/ rule does not).
    const re = try router.resolve(allocator, "/r/123") orelse return error.NoRoute;
    defer re.deinit();
    try std.testing.expectEqualStrings("/p/123", re.remote_path);
    // Neither rule matches /zzz.
    try std.testing.expect((try router.resolve(allocator, "/zzz")) == null);
}

test "router: blank local matches any path" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"plain\", \"local\": \"\", \"remote\": \"/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    // A blank local is a wildcard: it matches any path, and (unlike "/") the
    // empty prefix strips nothing, so the full path is the remainder.
    const a = try router.resolve(allocator, "/foo") orelse return error.NoRoute;
    defer a.deinit();
    try std.testing.expectEqualStrings("/foo", a.remote_path);
    const b = try router.resolve(allocator, "/") orelse return error.NoRoute;
    defer b.deinit();
    try std.testing.expectEqualStrings("/", b.remote_path);
    const c = try router.resolve(allocator, "/x/y/z") orelse return error.NoRoute;
    defer c.deinit();
    try std.testing.expectEqualStrings("/x/y/z", c.remote_path);
}

test "router: local and remote both / pass the source path through unchanged" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/\", \"remote\": \"/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    // local="/" matches any path and strips the leading slash; remote="/" then
    // re-adds it. The rewritten upstream path therefore equals the source path,
    // i.e. the URL passes through unchanged.
    const cases = [_][]const u8{ "/", "/a", "/a/b", "/a/b/c/d" };
    for (cases) |path| {
        const route = try router.resolve(allocator, path) orelse return error.NoRoute;
        defer route.deinit();
        try std.testing.expectEqualStrings(path, route.remote_path);
    }
}

test "router: all-root rule is a direct (identity) mapping" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    // Both local and remote omitted (blank is the default) -> the direct path:
    // it forwards the client path unchanged and borrows it (the route does not
    // own it, so deinit is a no-op).
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"plain\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const cases = [_][]const u8{ "/", "/a", "/a/b/c" };
    for (cases) |path| {
        const route = try router.resolve(allocator, path) orelse return error.NoRoute;
        defer route.deinit();
        try std.testing.expectEqualStrings(path, route.remote_path);
        try std.testing.expect(!route.owns_remote_path);
    }
}

test "router: root local with a non-root remote rewrites (not direct)" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    // local="" (root) matches any path, but remote is a real prefix, so this is
    // a genuine plain rewrite (prepend), NOT the direct/identity path.
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"plain\", \"local\": \"\", \"remote\": \"/x/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const route = try router.resolve(allocator, "/a/b") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expect(route.owns_remote_path);
    try std.testing.expectEqualStrings("/x/a/b", route.remote_path);
}

// Helper: resolve `path` and build the full upstream URL exactly as forward
// does (host ++ rewritten, normalized path), returning it as an allocated string.
fn resolvedUrl(allocator: Allocator, router: *const router_mod.Router, path: []const u8) ![]u8 {
    var route = try router.resolve(allocator, path) orelse return error.NoRoute;
    defer route.deinit();
    return allocator.print("{s}{s}", .{ route.upstream.host, route.remote_path });
}

test "router: wildcard local passes the source path through under the host" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://www.printables.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/\", \"remote\": \"\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const url = try resolvedUrl(allocator, &router, "/model/1801944-factorio-assembling-machine/files");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://www.printables.com/model/1801944-factorio-assembling-machine/files",
        url,
    );
}

test "router: local /printables strips the prefix to the host root" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://www.printables.com\", \"path\": [{\"type\": \"plain\", \"local\": \"/printables\", \"remote\": \"\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const url = try resolvedUrl(allocator, &router, "/printables/model/1801944-factorio-assembling-machine/files");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://www.printables.com/model/1801944-factorio-assembling-machine/files",
        url,
    );
}

test "router: root remote never doubles the leading slash" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://www.printables.com\", \"path\": [{\"type\": \"plain\", \"local\": \"\", \"remote\": \"/\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const url = try resolvedUrl(allocator, &router, "/model/123/files");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://www.printables.com/model/123/files", url);
}

test "config: regex path rule compiles and decodes" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();

    const json = "{\"upstream\": [{\"host\": \"https://x.com\", \"path\": [{\"type\": \"regex\", \"local\": \"/api/product/([0-9]+)/info\", \"remote\": \"/api/product/info/$1\"}]}]}";
    var cfg = try Config.load(io_ctx.io, allocator, null, json);
    defer cfg.deinit();

    const p = cfg.upstream[0].path[0];
    try std.testing.expectEqualStrings("regex", p.type);
    try std.testing.expectEqualStrings("/api/product/([0-9]+)/info", p.local);
    try std.testing.expectEqualStrings("/api/product/info/$1", p.remote);
}

test "router: regex rewrites with a capture group" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"regex\", \"local\": \"/api/product/([0-9]+)/info\", \"remote\": \"/api/product/info/$1\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const route = try router.resolve(allocator, "/api/product/1234/info") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("https://e.com", route.upstream.host);
    try std.testing.expectEqualStrings("/api/product/info/1234", route.remote_path);
}

test "router: regex requires a full match (partial is a non-match)" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"regex\", \"local\": \"/api/product/([0-9]+)/info\", \"remote\": \"/api/product/info/$1\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    // A trailing char makes the match partial (end != path.len): no route.
    try std.testing.expect((try router.resolve(allocator, "/api/product/1234/infoX")) == null);
    // A leading char makes the match partial (start != 0): no route.
    try std.testing.expect((try router.resolve(allocator, "/x/api/product/1234/info")) == null);
}

test "router: regex with multiple groups" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"regex\", \"local\": \"/a/([0-9]+)-([0-9]+)/b\", \"remote\": \"/x/$1/$2\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const route = try router.resolve(allocator, "/a/12-34/b") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("/x/12/34", route.remote_path);
}

test "router: regex $0 substitutes the whole match" {
    const allocator = std.testing.allocator;
    var io_ctx = try httpx.IoContext.init(allocator);
    defer io_ctx.deinit();
    var cfg = try loadConfig(allocator, &io_ctx, "{\"upstream\": [{\"host\": \"https://e.com\", \"path\": [{\"type\": \"regex\", \"local\": \"([0-9]+)\", \"remote\": \"/num/$0\"}]}]}");
    defer cfg.deinit();

    const router = router_mod.Router.init(cfg.upstream);
    const route = try router.resolve(allocator, "42") orelse return error.NoRoute;
    defer route.deinit();
    try std.testing.expectEqualStrings("/num/42", route.remote_path);
}

fn headerContains(hs: [][:0]const u8, prefix: []const u8) bool {
    for (hs) |h| {
        if (std.mem.startsWith(u8, h, prefix)) return true;
    }
    return false;
}

test "headers: buildRequestHeaders drops managed + applies overrides" {
    const allocator = std.testing.allocator;
    const fields = [_]httpx.http1.parser.Field{
        .{ .name = "Host", .value = "local:8080" },
        .{ .name = "Content-Length", .value = "5" },
        .{ .name = "Connection", .value = "keep-alive" },
        .{ .name = "Accept", .value = "text/html" },
        .{ .name = "Accept-Encoding", .value = "gzip, br" },
        .{ .name = "X-Delete", .value = "gone" },
        .{ .name = "X-Set", .value = "old" },
    };
    var overrides: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
    defer overrides.deinit(allocator);
    try overrides.put(allocator, "X-Delete", null);
    try overrides.put(allocator, "X-Set", "new");
    try overrides.put(allocator, "X-New", "added");

    const out = try headers_mod.buildRequestHeaders(allocator, &fields, &overrides, "https://upstream.example.com");
    defer {
        for (out) |s| allocator.free(s);
        allocator.free(out);
    }

    try std.testing.expect(headerContains(out, "Accept: "));
    // Accept-Encoding is relayed so upstream can compress for the client.
    try std.testing.expect(headerContains(out, "Accept-Encoding: gzip, br"));
    try std.testing.expect(!headerContains(out, "Host: "));
    try std.testing.expect(!headerContains(out, "Content-Length: "));
    try std.testing.expect(!headerContains(out, "Connection: "));
    try std.testing.expect(!headerContains(out, "X-Delete: "));
    try std.testing.expect(headerContains(out, "X-Set: new"));
    try std.testing.expect(!headerContains(out, "X-Set: old"));
    try std.testing.expect(headerContains(out, "X-New: added"));
}

test "headers: buildRequestHeaders overrides Origin with upstream origin" {
    const allocator = std.testing.allocator;
    const upstream_origin = "https://upstream.example.com";
    const with_origin = [_]httpx.http1.parser.Field{
        .{ .name = "Origin", .value = "https://client.example.com" },
        .{ .name = "Accept", .value = "text/html" },
    };
    const no_origin = [_]httpx.http1.parser.Field{
        .{ .name = "Accept", .value = "text/html" },
    };

    // 1) Client sends Origin; no per-upstream override -> upstream origin.
    {
        var ov: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
        defer ov.deinit(allocator);
        const out = try headers_mod.buildRequestHeaders(allocator, &with_origin, &ov, upstream_origin);
        defer {
            for (out) |s| allocator.free(s);
            allocator.free(out);
        }
        try std.testing.expect(headerContains(out, "Origin: https://upstream.example.com"));
        try std.testing.expect(!headerContains(out, "Origin: https://client.example.com"));
    }

    // 2) Per-upstream override present -> wins over the upstream origin.
    {
        var ov: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
        defer ov.deinit(allocator);
        try ov.put(allocator, "Origin", "https://custom.example.com");
        const out = try headers_mod.buildRequestHeaders(allocator, &with_origin, &ov, upstream_origin);
        defer {
            for (out) |s| allocator.free(s);
            allocator.free(out);
        }
        try std.testing.expect(headerContains(out, "Origin: https://custom.example.com"));
        try std.testing.expect(!headerContains(out, "Origin: https://upstream.example.com"));
    }

    // 3) Client did NOT send Origin -> not added by the upstream origin.
    {
        var ov: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
        defer ov.deinit(allocator);
        const out = try headers_mod.buildRequestHeaders(allocator, &no_origin, &ov, upstream_origin);
        defer {
            for (out) |s| allocator.free(s);
            allocator.free(out);
        }
        try std.testing.expect(!headerContains(out, "Origin: "));
    }
}

test "headers: buildResponseHead relays content-encoding, drops framing" {
    const allocator = std.testing.allocator;
    const fields = [_]httpx.http1.parser.Field{
        .{ .name = "Content-Length", .value = "10" },
        .{ .name = "Content-Encoding", .value = "gzip" },
        .{ .name = "Connection", .value = "keep-alive" },
        .{ .name = "X-Server", .value = "upstream" },
        .{ .name = "X-Override", .value = "old" },
    };
    var overrides: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
    defer overrides.deinit(allocator);
    try overrides.put(allocator, "X-Override", "new");
    try overrides.put(allocator, "X-Added", "yes");

    const head = try headers_mod.buildResponseHead(allocator, "HTTP/1.1 200 OK", &fields, &overrides, null);
    defer allocator.free(head);

    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, head, "\r\n\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head, "X-Server: upstream") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "X-Override: new") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "X-Override: old") == null);
    try std.testing.expect(std.mem.indexOf(u8, head, "X-Added: yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Length:") == null);
    // Content-Encoding is relayed verbatim (we no longer ask libcurl to decode).
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Encoding: gzip") != null);
    // The upstream's keep-alive is dropped; the proxy advertises its own close
    // (it terminates every client connection and relays the body by EOF).
    try std.testing.expect(std.mem.indexOf(u8, head, "Connection: keep-alive") == null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Connection: close") != null);
}

test "headers: buildResponseHead overrides Access-Control-Allow-Origin" {
    const allocator = std.testing.allocator;
    const acao_upstream = [_]httpx.http1.parser.Field{
        .{ .name = "Access-Control-Allow-Origin", .value = "https://upstream.example.com" },
        .{ .name = "X-Server", .value = "upstream" },
    };
    const acao_none = [_]httpx.http1.parser.Field{
        .{ .name = "X-Server", .value = "upstream" },
    };

    // 1) Upstream advertises ACAO; no per-upstream override, no --access-control-allow-origin -> "*".
    {
        var ov: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
        defer ov.deinit(allocator);
        const head = try headers_mod.buildResponseHead(allocator, "HTTP/1.1 200 OK", &acao_upstream, &ov, null);
        defer allocator.free(head);
        try std.testing.expect(std.mem.indexOf(u8, head, "Access-Control-Allow-Origin: *") != null);
        try std.testing.expect(std.mem.indexOf(u8, head, "upstream.example.com") == null);
    }

    // 2) Upstream advertises ACAO; no per-upstream override, --access-control-allow-origin set -> that value.
    {
        var ov: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
        defer ov.deinit(allocator);
        const head = try headers_mod.buildResponseHead(allocator, "HTTP/1.1 200 OK", &acao_upstream, &ov, "https://proxy.example.com");
        defer allocator.free(head);
        try std.testing.expect(std.mem.indexOf(u8, head, "Access-Control-Allow-Origin: https://proxy.example.com") != null);
        try std.testing.expect(std.mem.indexOf(u8, head, "upstream.example.com") == null);
    }

    // 3) Per-upstream override present -> beats --access-control-allow-origin and the upstream value.
    {
        var ov: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
        defer ov.deinit(allocator);
        try ov.put(allocator, "Access-Control-Allow-Origin", "https://custom.example.com");
        const head = try headers_mod.buildResponseHead(allocator, "HTTP/1.1 200 OK", &acao_upstream, &ov, "https://proxy.example.com");
        defer allocator.free(head);
        try std.testing.expect(std.mem.indexOf(u8, head, "Access-Control-Allow-Origin: https://custom.example.com") != null);
        try std.testing.expect(std.mem.indexOf(u8, head, "proxy.example.com") == null);
    }

    // 4) Upstream did NOT advertise ACAO -> the default does not add it.
    {
        var ov: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
        defer ov.deinit(allocator);
        const head = try headers_mod.buildResponseHead(allocator, "HTTP/1.1 200 OK", &acao_none, &ov, "https://proxy.example.com");
        defer allocator.free(head);
        try std.testing.expect(std.mem.indexOf(u8, head, "Access-Control-Allow-Origin") == null);
    }
}

// ---------------------------------------------------------------------------
// Integration tests: an in-process upstream + the Forwarder + a raw-socket
// client. Each request runs through real TCP sockets and one curl transfer,
// exercising the full relay path (request body in, response head+body out).
// ---------------------------------------------------------------------------

const IntError = error{ BindFailed, ConnectFailed, RelayFailed };

/// Read a request head (up to the blank line) plus its Content-Length body from
/// `socket`, returning the content-length (0 if the head carried none or the
/// read failed).
fn readUpstreamRequest(socket: tcp.Socket) usize {
    var buf: [16384]u8 = undefined;
    var total: usize = 0;
    var cl: usize = 0;
    head: while (true) {
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |_| {
            const head_bytes = buf[0..total];
            const head_res = parser.parseRequestHead(head_bytes, .{}) catch return cl;
            var fields: [parser.DEFAULT_MAX_HEADERS]parser.Field = undefined;
            const blk = parser.parseHeaderBlock(head_bytes, head_res.headEnd, &fields, .{}) catch return cl;
            for (fields[0..blk.count]) |f| {
                if (std.ascii.eqlIgnoreCase(f.name, "Content-Length")) {
                    cl = std.fmt.parseInt(usize, f.value, 10) catch return cl;
                }
            }
            break :head;
        }
        const n = socket.read(buf[total..]) catch return cl;
        if (n == 0) return cl;
        total += n;
    }
    var body_read: usize = 0;
    while (body_read < cl) {
        const n = socket.read(buf[total + body_read ..]) catch return cl;
        if (n == 0) return cl;
        body_read += n;
    }
    return cl;
}

/// Send the upstream's canned 200 reply: a marker header plus a body that echoes
/// the received content-length (so the client can verify the body was relayed).
fn respondUpstream(socket: tcp.Socket, allocator: std.mem.Allocator, cl: usize) void {
    const body = allocator.print("bodylen={d}\n", .{cl}) catch return;
    defer allocator.free(body);
    const resp = allocator.print("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Marker: up\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch return;
    defer allocator.free(resp);
    socket.writeAll(resp) catch return;
}

/// Serve one accepted upstream connection: read the request, echo bodylen.
fn serveUpstreamSocket(socket: tcp.Socket, allocator: std.mem.Allocator) void {
    defer socket.close();
    const cl = readUpstreamRequest(socket);
    respondUpstream(socket, allocator, cl);
}

/// In-process upstream: accept one connection and serve it.
fn upstreamOnce(listener: *tcp.Listener, io: std.Io, allocator: std.mem.Allocator) void {
    const socket = listener.accept(io) catch return;
    serveUpstreamSocket(socket, allocator);
}

/// Serve one accepted proxy connection: drive the forwarder, then close.
fn serveProxySocket(socket: tcp.Socket, allocator: std.mem.Allocator, forwarder: *forward_mod.Forwarder) void {
    var s = socket;
    forwarder.handle(allocator, &s);
    s.close();
}

/// Proxy handler: accept one connection and serve it.
fn proxyOnce(listener: *tcp.Listener, io: std.Io, allocator: std.mem.Allocator, forwarder: *forward_mod.Forwarder) void {
    const socket = listener.accept(io) catch return;
    serveProxySocket(socket, allocator, forwarder);
}

/// Wire an in-process upstream and the Forwarder against ephemeral ports, then
/// send `request` through the proxy with a raw-socket client and return the
/// full response bytes read until the proxy closes the connection.
fn relayRequest(io: std.Io, allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    // Upstream on an ephemeral port.
    var upstream = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer upstream.close(io);
    const upstream_port = upstream.localPort();

    // Forwarder configured to route everything to that upstream.
    const upstream_host = try allocator.print("http://127.0.0.1:{d}", .{upstream_port});
    defer allocator.free(upstream_host);
    const cfg_json = try allocator.print("{{\"upstream\":[{{\"host\":\"{s}\"}}]}}", .{upstream_host});
    defer allocator.free(cfg_json);
    var cfg = try Config.load(io, allocator, null, cfg_json);
    defer cfg.deinit();
    var forwarder = try forward_mod.Forwarder.init(cfg, false, false);

    // Proxy on an ephemeral port.
    var proxy = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer proxy.close(io);
    const proxy_port = proxy.localPort();

    const up_thread = try std.Thread.spawn(.{}, upstreamOnce, .{ &upstream, io, allocator });
    const proxy_thread = try std.Thread.spawn(.{}, proxyOnce, .{ &proxy, io, allocator, &forwarder });

    // Raw-socket client.
    var client = tcp.connect(io, "127.0.0.1", proxy_port) catch return IntError.ConnectFailed;
    defer client.close();
    client.writeAll(request) catch return IntError.RelayFailed;
    var resp = std.array_list.Managed(u8).init(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = client.read(&chunk) catch break;
        if (n == 0) break;
        try resp.appendSlice(chunk[0..n]);
    }

    up_thread.join();
    proxy_thread.join();

    return resp.toOwnedSlice();
}

// The relayed response buffer is returned owned by the page allocator (used
// because the proxy/upstream threads allocate concurrently and the
// DebugAllocator is not thread-safe). Page memory is reclaimed at process
// exit, so the caller intentionally does not free it.
test "integration: relay GET (no body)" {
    var io_ctx = try httpx.IoContext.init(std.testing.allocator);
    defer io_ctx.deinit();

    const request = "GET /hello HTTP/1.1\r\nHost: local\r\n\r\n";
    const resp = try relayRequest(io_ctx.io, std.heap.page_allocator, request);

    try std.testing.expect(std.mem.indexOf(u8, resp, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "X-Marker: up") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "bodylen=0") != null);
}

test "integration: relay GET with a Content-Length body" {
    var io_ctx = try httpx.IoContext.init(std.testing.allocator);
    defer io_ctx.deinit();

    // The body is relayed by framing, not method: a GET here carries a body.
    const request = "GET /withbody HTTP/1.1\r\nHost: local\r\nContent-Length: 5\r\n\r\nhello";
    const resp = try relayRequest(io_ctx.io, std.heap.page_allocator, request);

    try std.testing.expect(std.mem.indexOf(u8, resp, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "X-Marker: up") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "bodylen=5") != null);
}

// ---------------------------------------------------------------------------
// Chunked relay: a client chunked body is decoded and re-emitted to the
// upstream as chunked (no Content-Length), streamed in bounded memory. The
// payload is larger than the proxy's 128 KiB decoded buffer so the streaming
// (multi-read) path is exercised, not just "fits in one buffer".
// ---------------------------------------------------------------------------

/// Frame `chunks` as an HTTP chunked body: <hex-size>\r\n<data>\r\n ... 0\r\n\r\n
fn buildChunkedBody(allocator: std.mem.Allocator, chunks: []const []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    for (chunks) |c| {
        const hex = allocator.print("{x}", .{c.len}) catch return error.OutOfMemory;
        defer allocator.free(hex);
        try buf.appendSlice(hex);
        try buf.appendSlice("\r\n");
        try buf.appendSlice(c);
        try buf.appendSlice("\r\n");
    }
    try buf.appendSlice("0\r\n\r\n");
    return buf.toOwnedSlice();
}

/// Upstream handler for a chunked request: read the head, confirm it is
/// chunked (not Content-Length), decode the chunked body, and echo the framing
/// plus the decoded length.
fn serveUpstreamChunked(socket: tcp.Socket, allocator: std.mem.Allocator) void {
    defer socket.close();

    var head: [16384]u8 = undefined;
    var head_total: usize = 0;
    var seed_start: usize = 0;
    var is_chunked = false;
    head: while (true) {
        if (std.mem.indexOf(u8, head[0..head_total], "\r\n\r\n")) |blank| {
            const head_bytes = head[0 .. blank + 4];
            const head_res = parser.parseRequestHead(head_bytes, .{}) catch return;
            var fields: [parser.DEFAULT_MAX_HEADERS]parser.Field = undefined;
            const blk = parser.parseHeaderBlock(head_bytes, head_res.headEnd, &fields, .{}) catch return;
            for (fields[0..blk.count]) |f| {
                if (std.ascii.eqlIgnoreCase(f.name, "Transfer-Encoding") and std.mem.indexOf(u8, f.value, "chunked") != null) {
                    is_chunked = true;
                }
            }
            seed_start = blank + 4;
            break :head;
        }
        const n = socket.read(head[head_total..]) catch return;
        if (n == 0) return;
        head_total += n;
    }

    var decoded_total: usize = 0;
    var ok: bool = true;
    var work: [65536]u8 = undefined;
    var work_len: usize = 0;
    if (seed_start < head_total) {
        const seed_len = head_total - seed_start;
        @memcpy(work[0..seed_len], head[seed_start..head_total]);
        work_len = seed_len;
    }
    var decoder = parser.ChunkedDecoder.init();
    while (true) {
        const res = decoder.decode(work[0..work_len]);
        decoded_total += decoder.decodedLen;
        if (res) |_| {
            break; // terminating chunk reached.
        } else |err| {
            if (err != parser.ParseError.Incomplete) {
                ok = false;
                break;
            }
        }
        const keep = work_len - decoder.rawConsumed;
        if (keep > 0) std.mem.copyForwards(u8, work[0..keep], work[decoder.rawConsumed..work_len]);
        work_len = keep;
        const n = socket.read(work[work_len..]) catch return;
        if (n == 0) {
            ok = false; // EOF before the terminating chunk.
            break;
        }
        work_len += n;
    }

    const framing = if (is_chunked) "chunked" else "other";
    const ok_val: u32 = if (ok) 1 else 0;
    const body = allocator.print("framing={s} bodylen={d} ok={d}\n", .{ framing, decoded_total, ok_val }) catch return;
    defer allocator.free(body);
    const resp = allocator.print("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Marker: up\r\nX-Framing: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ framing, body.len, body }) catch return;
    defer allocator.free(resp);
    socket.writeAll(resp) catch return;
}

fn serveUpstreamChunkedOnce(listener: *tcp.Listener, io: std.Io, allocator: std.mem.Allocator) void {
    const socket = listener.accept(io) catch return;
    serveUpstreamChunked(socket, allocator);
}

/// Relay `request` through the proxy against a chunked-aware upstream and
/// return the full response bytes.
fn relayChunkedRequest(io: std.Io, allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    var upstream = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer upstream.close(io);
    const upstream_port = upstream.localPort();

    const upstream_host = try allocator.print("http://127.0.0.1:{d}", .{upstream_port});
    defer allocator.free(upstream_host);
    const cfg_json = try allocator.print("{{\"upstream\":[{{\"host\":\"{s}\"}}]}}", .{upstream_host});
    defer allocator.free(cfg_json);
    var cfg = try Config.load(io, allocator, null, cfg_json);
    defer cfg.deinit();
    var forwarder = try forward_mod.Forwarder.init(cfg, false, false);

    var proxy = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer proxy.close(io);
    const proxy_port = proxy.localPort();

    const up_thread = try std.Thread.spawn(.{}, serveUpstreamChunkedOnce, .{ &upstream, io, allocator });
    const proxy_thread = try std.Thread.spawn(.{}, proxyOnce, .{ &proxy, io, allocator, &forwarder });

    var client = tcp.connect(io, "127.0.0.1", proxy_port) catch return IntError.ConnectFailed;
    defer client.close();
    client.writeAll(request) catch return IntError.RelayFailed;
    var resp = std.array_list.Managed(u8).init(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = client.read(&chunk) catch break;
        if (n == 0) break;
        try resp.appendSlice(chunk[0..n]);
    }

    up_thread.join();
    proxy_thread.join();

    return resp.toOwnedSlice();
}

test "integration: relay a chunked body (chunked in -> chunked out)" {
    const allocator = std.heap.page_allocator;
    var io_ctx = try httpx.IoContext.init(std.testing.allocator);
    defer io_ctx.deinit();

    // 300 KiB payload (> the 128 KiB decoded buffer) split into a few chunks.
    const body_size: usize = 300 * 1024;
    const payload = try allocator.alloc(u8, body_size);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @as(u8, @intCast(i % 251));
    const chunked_body = try buildChunkedBody(allocator, &.{
        payload[0 .. 100 * 1024],
        payload[100 * 1024 .. 250 * 1024],
        payload[250 * 1024 ..],
    });
    defer allocator.free(chunked_body);

    const request = try std.mem.concat(allocator, u8, &.{
        "POST /chunked HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\nContent-Type: application/octet-stream\r\n\r\n",
        chunked_body,
    });
    defer allocator.free(request);
    const resp = try relayChunkedRequest(io_ctx.io, allocator, request);

    try std.testing.expect(std.mem.indexOf(u8, resp, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "X-Framing: chunked") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "bodylen=307200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ok=1") != null);
}

// ---------------------------------------------------------------------------
// Overall-timeout integration test: an upstream that accepts the connection
// but never responds. The proxy's overall (transfer) timeout is set to a small
// value, so the transfer trips it and the proxy 502s — instead of waiting the
// 15-minute default (which would hang the test).
// ---------------------------------------------------------------------------

/// Upstream handler that accepts the connection and holds it open for
/// `hold_ns` without ever responding, so the proxy's transfer runs until it
/// trips the overall (transfer) timeout. Uses a wall-clock deadline + yield
/// (0.17 has no std.Thread.sleep), the same pattern the concurrency barrier
/// uses. `hold_ns` is set above the overall timeout so the connection is still
/// open (but unresponsive) when the proxy gives up.
fn serveUpstreamSilent(socket: tcp.Socket, hold_ns: i64) void {
    defer socket.close();
    const deadline = std.Io.Timestamp.now(socket.io, .awake);
    while (deadline.durationTo(std.Io.Timestamp.now(socket.io, .awake)).nanoseconds < hold_ns) {
        std.Thread.yield() catch {};
    }
}

fn serveUpstreamSilentOnce(listener: *tcp.Listener, io: std.Io, hold_ns: i64) void {
    const socket = listener.accept(io) catch return;
    serveUpstreamSilent(socket, hold_ns);
}

test "integration: small overall timeout is hit (502, no hang)" {
    const allocator = std.heap.page_allocator;
    var io_ctx = try httpx.IoContext.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io;

    // Upstream accepts but never responds, holding the connection open for
    // 2500ms — longer than the 2000ms overall timeout below.
    var upstream = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer upstream.close(io);
    const upstream_port = upstream.localPort();

    const upstream_host = try allocator.print("http://127.0.0.1:{d}", .{upstream_port});
    defer allocator.free(upstream_host);
    // Small overall (transfer) timeout + an even smaller connect timeout, so
    // the local connect succeeds but the never-arriving response trips the
    // overall budget (the connect budget does not fire first).
    const cfg_json = try allocator.print("{{\"timeout_ms\":2000,\"connect_timeout_ms\":500,\"upstream\":[{{\"host\":\"{s}\"}}]}}", .{upstream_host});
    defer allocator.free(cfg_json);
    var cfg = try Config.load(io, allocator, null, cfg_json);
    defer cfg.deinit();
    var forwarder = try forward_mod.Forwarder.init(cfg, false, false);

    var proxy = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer proxy.close(io);
    const proxy_port = proxy.localPort();

    const hold_ns: i64 = 2500 * 1_000_000; // 2500ms
    const up_thread = try std.Thread.spawn(.{}, serveUpstreamSilentOnce, .{ &upstream, io, hold_ns });
    const proxy_thread = try std.Thread.spawn(.{}, proxyOnce, .{ &proxy, io, allocator, &forwarder });

    var client = tcp.connect(io, "127.0.0.1", proxy_port) catch return IntError.ConnectFailed;
    defer client.close();
    client.writeAll("GET /slow HTTP/1.1\r\nHost: local\r\n\r\n") catch return IntError.RelayFailed;
    var resp = std.array_list.Managed(u8).init(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = client.read(&chunk) catch break;
        if (n == 0) break;
        try resp.appendSlice(chunk[0..n]);
    }

    up_thread.join();
    proxy_thread.join();

    const body = try resp.toOwnedSlice();
    // The proxy 502s once the overall timeout trips (the upstream never replied).
    try std.testing.expect(std.mem.indexOf(u8, body, "HTTP/1.1 502") != null);
}

// ---------------------------------------------------------------------------
// Concurrency test: submit N parallel requests and verify the proxy handles
// them all at once. The proxy is driven the same way production runs it
// (thread-per-connection in an accept loop, like server.zig). A barrier in the
// upstream proves all N requests are in flight simultaneously, without any
// timing-based assertion, so the test is not flaky.
// ---------------------------------------------------------------------------

const N_CONCURRENT: usize = 5;
/// The barrier's give-up deadline, as a wall-clock interval read from the
/// socket's Io clock (0.17 removed std.time timestamps, so std.Io.Timestamp is
/// used). Each wait iteration yields the CPU (std.Thread.yield), so a handler
/// waiting at the barrier never starves the other handler threads that still
/// have to reach it. This matters on a small, contended runner (CI): a tight
/// spin there hogs a core and the N-1 stragglers never make progress in time,
/// so a healthy concurrent proxy gets misreported as not reaching the barrier.
/// The deadline bounds how long a NON-concurrent proxy keeps a handler waiting
/// before the test fails instead of hanging; it must comfortably exceed the
/// stagger between the N handler threads arriving, or a healthy proxy can be
/// misreported as serial. A yield count (the previous bound) was too coarse: on
/// a contended runner 10M yields elapse in well under a second, before the
/// stragglers arrive, so the barrier was misreported as unreached. A wall-clock
/// deadline is runner-independent. It stays below the overall timeout (60000ms)
/// so a slow-but-concurrent barrier still 200s rather than 502s.
const BARRIER_TIMEOUT_NS: i64 = 20 * 1_000_000_000; // 20s
var in_flight: usize = 0;
var barrier_reached: bool = true;

/// Upstream handler with a concurrency barrier: read the request, count
/// ourselves in flight, and (cooperatively) wait until all N_CONCURRENT are in
/// flight at once (proving the proxy handled them concurrently). If the proxy is
/// not concurrent the barrier is never reached; after BARRIER_TIMEOUT_NS we mark
/// it unreached so the test fails instead of hanging.
fn serveUpstreamBarrier(socket: tcp.Socket, allocator: std.mem.Allocator) void {
    const cl = readUpstreamRequest(socket);
    _ = @atomicRmw(usize, &in_flight, .Add, 1, .monotonic);
    const deadline = std.Io.Timestamp.now(socket.io, .awake);
    while (@atomicLoad(usize, &in_flight, .monotonic) < N_CONCURRENT) {
        if (deadline.durationTo(std.Io.Timestamp.now(socket.io, .awake)).nanoseconds >= BARRIER_TIMEOUT_NS) {
            @atomicStore(bool, &barrier_reached, false, .monotonic);
            break;
        }
        std.Thread.yield() catch {};
    }
    // The handler always runs to completion (readUpstreamRequest /
    // respondUpstream swallow their errors), so decrement + close on the
    // single fall-through path below.
    respondUpstream(socket, allocator, cl);
    _ = @atomicRmw(usize, &in_flight, .Sub, 1, .monotonic);
    socket.close();
}

/// Upstream pool: accept `n` connections, spawning a barrier handler per
/// connection (thread-per-connection), then join them all before returning.
fn upstreamPoolBarrier(listener: *tcp.Listener, io: std.Io, allocator: std.mem.Allocator, threads: []std.Thread, n: usize) void {
    var count: usize = 0;
    while (count < n) {
        const socket = listener.accept(io) catch return;
        const t = std.Thread.spawn(.{}, serveUpstreamBarrier, .{ socket, allocator }) catch {
            socket.close();
            continue;
        };
        threads[count] = t;
        count += 1;
    }
    for (threads[0..count]) |*t| t.join();
}

/// Proxy pool: accept `n` connections, spawning a forwarder handler per
/// connection (thread-per-connection, mirroring server.zig), then join them all.
fn proxyPool(listener: *tcp.Listener, io: std.Io, allocator: std.mem.Allocator, forwarder: *forward_mod.Forwarder, threads: []std.Thread, n: usize) void {
    var count: usize = 0;
    while (count < n) {
        const socket = listener.accept(io) catch return;
        const t = std.Thread.spawn(.{}, serveProxySocket, .{ socket, allocator, forwarder }) catch {
            socket.close();
            continue;
        };
        threads[count] = t;
        count += 1;
    }
    for (threads[0..count]) |*t| t.join();
}

test "integration: N concurrent requests are all in flight at once" {
    const allocator = std.heap.page_allocator;
    var io_ctx = try httpx.IoContext.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io;
    const n: usize = N_CONCURRENT;

    @atomicStore(usize, &in_flight, 0, .monotonic);
    @atomicStore(bool, &barrier_reached, true, .monotonic);

    var upstream = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer upstream.close(io);
    const upstream_port = upstream.localPort();
    const upstream_host = try allocator.print("http://127.0.0.1:{d}", .{upstream_port});
    defer allocator.free(upstream_host);
    // The upstream handlers hold their connection at the barrier until all N
    // requests are in flight, so the proxy's libcurl transfers wait that long
    // for a response. Give the overall (transfer) timeout a value comfortably
    // above the 20s barrier so a contended runner (slow barrier) can't trip it
    // and 502 the requests before the barrier is reached, while still bounding
    // the test's worst-case runtime well below the 15min default.
    const cfg_json = try allocator.print("{{\"timeout_ms\":60000,\"upstream\":[{{\"host\":\"{s}\"}}]}}", .{upstream_host});
    defer allocator.free(cfg_json);
    var cfg = try Config.load(io, allocator, null, cfg_json);
    defer cfg.deinit();
    var forwarder = try forward_mod.Forwarder.init(cfg, false, false);

    var proxy = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer proxy.close(io);
    const proxy_port = proxy.localPort();

    var up_threads: [n]std.Thread = undefined;
    var px_threads: [n]std.Thread = undefined;

    const up_pool = try std.Thread.spawn(.{}, upstreamPoolBarrier, .{ &upstream, io, allocator, &up_threads, n });
    const px_pool = try std.Thread.spawn(.{}, proxyPool, .{ &proxy, io, allocator, &forwarder, &px_threads, n });

    // Open all n clients and submit all n requests before reading any
    // response, so all n are in flight at the proxy at the same time.
    var clients: [n]tcp.Socket = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        clients[i] = tcp.connect(io, "127.0.0.1", proxy_port) catch return IntError.ConnectFailed;
        const req = try allocator.print("GET /req{d} HTTP/1.1\r\nHost: local\r\n\r\n", .{i});
        clients[i].writeAll(req) catch {
            allocator.free(req);
            return IntError.RelayFailed;
        };
        allocator.free(req);
    }

    // Read and verify all n responses.
    i = 0;
    while (i < n) : (i += 1) {
        var resp = std.array_list.Managed(u8).init(allocator);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const got = clients[i].read(&chunk) catch break;
            if (got == 0) break;
            try resp.appendSlice(chunk[0..got]);
        }
        const bytes = try resp.toOwnedSlice();
        try std.testing.expect(std.mem.indexOf(u8, bytes, "HTTP/1.1 200") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "X-Marker: up") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "bodylen=0") != null);
        allocator.free(bytes);
        clients[i].close();
    }

    up_pool.join();
    px_pool.join();

    // The barrier proves all n requests were in flight simultaneously.
    try std.testing.expect(@atomicLoad(bool, &barrier_reached, .monotonic));
}

// ---------------------------------------------------------------------------
// Client-fault and interim-response tests: malformed heads and short bodies
// are 400 (the client's fault), 1xx interims are skipped, and
// Expect: 100-continue is answered by the proxy itself.
// ---------------------------------------------------------------------------

/// Upstream that sends a 100 Continue interim block, then the final 200.
fn serveUpstreamInterimOnce(listener: *tcp.Listener, io: std.Io, allocator: std.mem.Allocator) void {
    const socket = listener.accept(io) catch return;
    defer socket.close();
    _ = readUpstreamRequest(socket);
    const body = "ok\n";
    const final = allocator.print("HTTP/1.1 200 OK\r\nX-Marker: up\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch return;
    defer allocator.free(final);
    socket.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch return;
    socket.writeAll(final) catch return;
}

/// The Forwarder configured against one upstream (the caller deinit()s cfg).
const Relay = struct {
    cfg: *Config,
    forwarder: forward_mod.Forwarder,
};

/// Load a config that routes everything to the given upstream port and build
/// the Forwarder for it.
fn relaySetup(io: std.Io, allocator: std.mem.Allocator, upstream_port: u16) !Relay {
    const upstream_host = try allocator.print("http://127.0.0.1:{d}", .{upstream_port});
    defer allocator.free(upstream_host);
    const cfg_json = try allocator.print("{{\"upstream\":[{{\"host\":\"{s}\"}}]}}", .{upstream_host});
    defer allocator.free(cfg_json);
    const cfg = try Config.load(io, allocator, null, cfg_json);
    const forwarder = try forward_mod.Forwarder.init(cfg, false, false);
    return .{ .cfg = cfg, .forwarder = forwarder };
}

test "integration: malformed request head is a 400" {
    const allocator = std.heap.page_allocator;
    var io_ctx = try httpx.IoContext.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io;

    var upstream = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer upstream.close(io);
    var relay = try relaySetup(io, allocator, upstream.localPort());
    defer relay.cfg.deinit();

    var proxy = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer proxy.close(io);
    const proxy_port = proxy.localPort();
    const proxy_thread = try std.Thread.spawn(.{}, proxyOnce, .{ &proxy, io, allocator, &relay.forwarder });

    var client = tcp.connect(io, "127.0.0.1", proxy_port) catch return IntError.ConnectFailed;
    defer client.close();
    // Not a request line at all: the head fails to parse -> 400, not a silent
    // close.
    client.writeAll("GARBAGE\r\n\r\n") catch return IntError.RelayFailed;
    var resp = std.array_list.Managed(u8).init(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = client.read(&chunk) catch break;
        if (n == 0) break;
        try resp.appendSlice(chunk[0..n]);
    }
    proxy_thread.join();
    const body = try resp.toOwnedSlice();
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "HTTP/1.1 400") != null);
}

test "integration: short Content-Length body is a 400" {
    const allocator = std.heap.page_allocator;
    var io_ctx = try httpx.IoContext.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io;

    var upstream = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer upstream.close(io);
    var relay = try relaySetup(io, allocator, upstream.localPort());
    defer relay.cfg.deinit();

    var proxy = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer proxy.close(io);
    const proxy_port = proxy.localPort();
    const proxy_thread = try std.Thread.spawn(.{}, proxyOnce, .{ &proxy, io, allocator, &relay.forwarder });

    var client = tcp.connect(io, "127.0.0.1", proxy_port) catch return IntError.ConnectFailed;
    defer client.close();
    // Declare 10 body bytes, send only 5, then half-close the write side so
    // the proxy sees EOF before the declared length arrives.
    client.writeAll("POST /short HTTP/1.1\r\nHost: local\r\nContent-Length: 10\r\n\r\nabc") catch return IntError.RelayFailed;
    client.shutdownWrite();
    var resp = std.array_list.Managed(u8).init(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = client.read(&chunk) catch break;
        if (n == 0) break;
        try resp.appendSlice(chunk[0..n]);
    }
    proxy_thread.join();
    const body = try resp.toOwnedSlice();
    defer allocator.free(body);
    // The upload is the client's fault: 400, and no 502.
    try std.testing.expect(std.mem.indexOf(u8, body, "HTTP/1.1 400") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "HTTP/1.1 502") == null);
}

test "integration: 1xx interim is skipped and the final head is relayed" {
    const allocator = std.heap.page_allocator;
    var io_ctx = try httpx.IoContext.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io;

    var upstream = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer upstream.close(io);
    var relay = try relaySetup(io, allocator, upstream.localPort());
    defer relay.cfg.deinit();

    var proxy = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer proxy.close(io);
    const proxy_port = proxy.localPort();
    const up_thread = try std.Thread.spawn(.{}, serveUpstreamInterimOnce, .{ &upstream, io, allocator });
    const proxy_thread = try std.Thread.spawn(.{}, proxyOnce, .{ &proxy, io, allocator, &relay.forwarder });

    var client = tcp.connect(io, "127.0.0.1", proxy_port) catch return IntError.ConnectFailed;
    defer client.close();
    client.writeAll("GET /interim HTTP/1.1\r\nHost: local\r\n\r\n") catch return IntError.RelayFailed;
    var resp = std.array_list.Managed(u8).init(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = client.read(&chunk) catch break;
        if (n == 0) break;
        try resp.appendSlice(chunk[0..n]);
    }
    up_thread.join();
    proxy_thread.join();
    const body = try resp.toOwnedSlice();
    defer allocator.free(body);
    // The final 200 (and its body) must reach the client, and the 100 interim
    // must NOT be relayed as if it were the final head.
    try std.testing.expect(std.mem.indexOf(u8, body, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "X-Marker: up") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "100 Continue") == null);
}

test "integration: Expect 100-continue is answered with 100 before the body" {
    const allocator = std.heap.page_allocator;
    var io_ctx = try httpx.IoContext.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io;

    var upstream = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer upstream.close(io);
    var relay = try relaySetup(io, allocator, upstream.localPort());
    defer relay.cfg.deinit();

    var proxy = tcp.Listener.bind(io, 0) catch return IntError.BindFailed;
    defer proxy.close(io);
    const proxy_port = proxy.localPort();
    const up_thread = try std.Thread.spawn(.{}, upstreamOnce, .{ &upstream, io, allocator });
    const proxy_thread = try std.Thread.spawn(.{}, proxyOnce, .{ &proxy, io, allocator, &relay.forwarder });

    var client = tcp.connect(io, "127.0.0.1", proxy_port) catch return IntError.ConnectFailed;
    defer client.close();
    // Send the head (with Expect) but hold back the body: the proxy must grant
    // the 100 before the body is sent.
    client.writeAll("POST /e HTTP/1.1\r\nHost: local\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n") catch return IntError.RelayFailed;
    var resp = std.array_list.Managed(u8).init(allocator);
    var chunk: [4096]u8 = undefined;
    // Read until the proxy's 100 arrives (or EOF).
    var got_100 = false;
    while (!got_100) {
        const n = client.read(&chunk) catch break;
        if (n == 0) break;
        try resp.appendSlice(chunk[0..n]);
        got_100 = std.mem.indexOf(u8, resp.items, "HTTP/1.1 100") != null;
    }
    // Now send the body and drain the final response.
    client.writeAll("hello") catch return IntError.RelayFailed;
    while (true) {
        const n = client.read(&chunk) catch break;
        if (n == 0) break;
        try resp.appendSlice(chunk[0..n]);
    }
    up_thread.join();
    proxy_thread.join();
    const body = try resp.toOwnedSlice();
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "HTTP/1.1 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bodylen=5") != null);
}

test "headers: Host/User-Agent are overridable, framing headers are not" {
    const allocator = std.testing.allocator;
    const fields = [_]httpx.http1.parser.Field{
        .{ .name = "Host", .value = "local:8080" },
        .{ .name = "User-Agent", .value = "client/1.0" },
        .{ .name = "Expect", .value = "100-continue" },
        .{ .name = "Connection", .value = "keep-alive" },
        .{ .name = "Accept", .value = "text/html" },
    };
    var overrides: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
    defer overrides.deinit(allocator);
    try overrides.put(allocator, "Host", "custom.example.com");
    // null => delete the client's UA (libcurl's default applies upstream)
    try overrides.put(allocator, "User-Agent", null);
    // Framing headers cannot be overridden: the drop wins.
    try overrides.put(allocator, "Connection", "should-not-appear");
    try overrides.put(allocator, "X-Added", "yes");

    const out = try headers_mod.buildRequestHeaders(allocator, &fields, &overrides, "https://upstream.example.com");
    defer {
        for (out) |s| allocator.free(s);
        allocator.free(out);
    }
    try std.testing.expect(headerContains(out, "Host: custom.example.com"));
    try std.testing.expect(!headerContains(out, "Host: local:8080"));
    try std.testing.expect(!headerContains(out, "User-Agent: "));
    try std.testing.expect(!headerContains(out, "Expect: "));
    try std.testing.expect(!headerContains(out, "Connection: "));
    try std.testing.expect(headerContains(out, "Accept: "));
    try std.testing.expect(headerContains(out, "X-Added: yes"));

    // An override may also SET the managed User-Agent when the client's is
    // relayed.
    {
        var ov2: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
        defer ov2.deinit(allocator);
        try ov2.put(allocator, "User-Agent", "custom-ua");
        const out2 = try headers_mod.buildRequestHeaders(allocator, &fields, &ov2, "https://upstream.example.com");
        defer {
            for (out2) |s| allocator.free(s);
            allocator.free(out2);
        }
        try std.testing.expect(headerContains(out2, "User-Agent: custom-ua"));
        try std.testing.expect(!headerContains(out2, "User-Agent: client/1.0"));
    }
}

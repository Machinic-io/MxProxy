const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config");
const pathmap_mod = @import("pathmap");
const router_mod = @import("router");

// Spock-style parameterized tests: every scenario is a row in one of the
// tables below, and a single test loops over the rows. Zig discovers tests
// statically (rows cannot become individually named tests), so on failure
// the diagnostics print the row's description, input, and got/want instead.

/// One rule of a test scenario.
const Rule = struct {
    @"type": []const u8,
    local: []const u8,
    remote: []const u8,
};

/// One upstream of a test scenario: its host plus the rules it carries.
const UpstreamSpec = struct {
    host: []const u8,
    rules: []const Rule,
};

/// The expected route when the input matches.
const Expect = struct {
    host: []const u8,
    path: []const u8,
};

/// One parameterized row (a Spock "where:" entry).
const Case = struct {
    /// Description printed with the failure diagnostic.
    desc: []const u8,
    upstreams: []const UpstreamSpec,
    input: []const u8,
    /// Expected route; null means the input must not route.
    expected: ?Expect = null,
    /// When true, the route must borrow the client path instead of
    /// allocating one (the catch-all and identity rewrites).
    expect_borrowed: bool = false,
};

/// `([0-9]+)-([0-9]+)-...` with exactly 12 capture groups.
const twelveGroupsPattern: [107]u8 = blk: {
    var buf: [107]u8 = undefined;
    var i: comptime_int = 0;
    for (0..12) |k| {
        if (k > 0) {
            buf[i] = '-';
            i += 1;
        }
        @memcpy(buf[i..][0..8], "([0-9]+)");
        i += 8;
    }
    break :blk buf;
};

/// 999 one-char capture groups: `(.)(.)...(.)(.)` (999 of them).
const dotGroups999Pattern: [2997]u8 = blk: {
    @setEvalBranchQuota(100_000); // the 999-iteration comptime loop
    var buf: [2997]u8 = undefined;
    var i: comptime_int = 0;
    for (0..999) |_| {
        @memcpy(buf[i..][0..3], "(.)");
        i += 3;
    }
    break :blk buf;
};

/// A 999-char input whose Nth (1-based) char is the digit (N-1) % 10.
const digits999Input: [999]u8 = blk: {
    @setEvalBranchQuota(100_000); // the 999-iteration comptime loop
    var buf: [999]u8 = undefined;
    for (0..999) |i| buf[i] = @as(u8, i % 10) + '0';
    break :blk buf;
};

const Built = struct {
    rules: []pathmap_mod.PathMapping,
    ups: []config_mod.Upstream,
};

/// Total number of rules across all upstreams of a scenario.
fn totalRules(comptime spec: []const UpstreamSpec) comptime_int {
    var n: comptime_int = 0;
    inline for (spec) |u| n += u.rules.len;
    return n;
}

/// Build the runtime rules/upstreams for one scenario. `spec` is comptime so
/// the storage sizes are known at compile time.
fn buildSpec(allocator: Allocator, comptime spec: []const UpstreamSpec) !Built {
    const n_rules: usize = totalRules(spec);

    const rules = try allocator.alloc(pathmap_mod.PathMapping, n_rules);
    var built: usize = 0;
    errdefer {
        for (rules[0..built]) |*r| {
            if (r.deinit) |release| release(r);
        }
        allocator.free(rules);
    }
    const ups = try allocator.alloc(config_mod.Upstream, spec.len);
    errdefer allocator.free(ups);

    for (spec, 0..) |u, i| {
        const start = built;
        for (u.rules) |r| {
            rules[built] = try pathmap_mod.buildPathMapping(allocator, r.type, r.local, r.remote);
            built += 1;
        }
        ups[i] = .{ .host = u.host, .path = rules[start..built] };
    }
    return .{ .rules = rules, .ups = ups };
}

/// Print a failure diagnostic for a scenario that produced no route.
fn mismatch(c: Case, detail: []const u8) noreturn {
    std.debug.print("router case failed: {s}: {s} (input {s})\n", .{ c.desc, detail, c.input });
    @panic("router case failed");
}

/// Run one scenario: build its rules, resolve the input, check the outcome.
/// `c` is comptime so `buildSpec` can size its storage at compile time.
fn check(allocator: Allocator, comptime c: Case) !void {
    const built = try buildSpec(allocator, c.upstreams);
    defer {
        for (built.rules) |*r| {
            if (r.deinit) |release| release(r);
        }
        allocator.free(built.rules);
        allocator.free(built.ups);
    }
    const router = router_mod.Router.init(built.ups);

    const opt = try router.resolve(allocator, c.input);
    if (opt) |route| {
        defer route.deinit();
        const want = c.expected orelse mismatch(c, "expected no route, found one");
        if (!std.mem.eql(u8, route.upstream.host, want.host) or
            !std.mem.eql(u8, route.remote_path, want.path))
        {
            std.debug.print("router case failed: {s}\n  input: {s}\n  got:   {s} {s}\n  want:  {s} {s}\n", .{
                c.desc, c.input, route.upstream.host, route.remote_path, want.host, want.path,
            });
            @panic("router case failed");
        }
        if (c.expect_borrowed and route.owns_remote_path) {
            mismatch(c, "expected the route to borrow the client path");
        }
    } else if (c.expected != null) {
        mismatch(c, "expected a route, found none");
    }
}

// ---------------------------------------------------------------------------
// Dispatch: matching order, catch-all, no-route
// ---------------------------------------------------------------------------

const dispatch_cases = [_]Case{
    .{
        .desc = "first match wins across upstreams",
        .upstreams = &.{
            .{ .host = "https://first.com", .rules = &.{.{ .type = "plain", .local = "/x/", .remote = "/1/" }} },
            .{ .host = "https://second.com", .rules = &.{.{ .type = "plain", .local = "/x/", .remote = "/2/" }} },
        },
        .input = "/x/y",
        .expected = .{ .host = "https://first.com", .path = "/1/y" },
    },
    .{
        .desc = "first rule wins within one upstream",
        .upstreams = &.{.{
            .host = "https://e.com",
            .rules = &.{
                .{ .type = "plain", .local = "/a/", .remote = "/1/" },
                .{ .type = "plain", .local = "/a/b/", .remote = "/2/" },
            },
        }},
        .input = "/a/b/x",
        .expected = .{ .host = "https://e.com", .path = "/1/b/x" },
    },
    .{
        .desc = "later rule matches when earlier does not",
        .upstreams = &.{.{
            .host = "https://e.com",
            .rules = &.{
                .{ .type = "plain", .local = "/a/", .remote = "/1/" },
                .{ .type = "plain", .local = "/b/", .remote = "/2/" },
            },
        }},
        .input = "/b/x",
        .expected = .{ .host = "https://e.com", .path = "/2/x" },
    },
    .{
        .desc = "rule match beats the catch-all",
        .upstreams = &.{
            .{ .host = "https://specific.com", .rules = &.{.{ .type = "plain", .local = "/api/", .remote = "/" }} },
            .{ .host = "https://default.com", .rules = &.{} },
        },
        .input = "/api/v1/users",
        .expected = .{ .host = "https://specific.com", .path = "/v1/users" },
    },
    .{
        .desc = "catch-all passthrough borrows the client path",
        .upstreams = &.{
            .{ .host = "https://specific.com", .rules = &.{.{ .type = "plain", .local = "/api/", .remote = "/" }} },
            .{ .host = "https://default.com", .rules = &.{} },
        },
        .input = "/other/thing",
        .expected = .{ .host = "https://default.com", .path = "/other/thing" },
        .expect_borrowed = true,
    },
    .{
        .desc = "no match and no catch-all returns null",
        .upstreams = &.{.{
            .host = "https://s.com",
            .rules = &.{.{ .type = "plain", .local = "/api/", .remote = "/" }},
        }},
        .input = "/nope",
    },
};

test "router: dispatch cases" {
    const allocator = std.testing.allocator;
    inline for (dispatch_cases) |c| try check(allocator, c);
}

// ---------------------------------------------------------------------------
// Rewrites: plain splicing, full-match, and the replacement template syntax
// ($0/$1..$9, ${0}..${999}, \$ escaping)
// ---------------------------------------------------------------------------

const rewrite_cases = [_]Case{
    // Plain prefix splicing.
    .{
        .desc = "plain: trailing-slash remote splices the remainder",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "plain", .local = "/a/", .remote = "/b/" }} }},
        .input = "/a/x",
        .expected = .{ .host = "https://e.com", .path = "/b/x" },
    },
    .{
        .desc = "plain: matching exactly the prefix leaves no trailing slash",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "plain", .local = "/a/", .remote = "/b/" }} }},
        .input = "/a/",
        .expected = .{ .host = "https://e.com", .path = "/b" },
    },
    .{
        .desc = "plain: slash-less remote joins the same way",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "plain", .local = "/a/", .remote = "/b" }} }},
        .input = "/a/x",
        .expected = .{ .host = "https://e.com", .path = "/b/x" },
    },
    .{
        .desc = "plain: slash-less local leaves no leading slash in the remainder",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "plain", .local = "/a", .remote = "/b/" }} }},
        .input = "/a/x",
        .expected = .{ .host = "https://e.com", .path = "/b/x" },
    },
    .{
        .desc = "plain: root local matches everything",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "plain", .local = "/", .remote = "/base/" }} }},
        .input = "/anything/at/all",
        .expected = .{ .host = "https://e.com", .path = "/base/anything/at/all" },
    },
    .{
        .desc = "plain: all-root rule is a borrowed identity",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "plain", .local = "", .remote = "" }} }},
        .input = "/p/q",
        .expected = .{ .host = "https://e.com", .path = "/p/q" },
        .expect_borrowed = true,
    },
    // Plain and regex rules dispatch by type.
    .{
        .desc = "dispatch by type: plain rule matches",
        .upstreams = &.{.{
            .host = "https://e.com",
            .rules = &.{
                .{ .type = "plain", .local = "/api/", .remote = "/p/" },
                .{ .type = "regex", .local = "x([0-9]+)", .remote = "/r/$1" },
            },
        }},
        .input = "/api/a",
        .expected = .{ .host = "https://e.com", .path = "/p/a" },
    },
    .{
        .desc = "dispatch by type: regex rule matches",
        .upstreams = &.{.{
            .host = "https://e.com",
            .rules = &.{
                .{ .type = "plain", .local = "/api/", .remote = "/p/" },
                .{ .type = "regex", .local = "x([0-9]+)", .remote = "/r/$1" },
            },
        }},
        .input = "x42",
        .expected = .{ .host = "https://e.com", .path = "/r/42" },
    },
    .{
        .desc = "dispatch by type: non-matching input routes nowhere",
        .upstreams = &.{.{
            .host = "https://e.com",
            .rules = &.{
                .{ .type = "plain", .local = "/api/", .remote = "/p/" },
                .{ .type = "regex", .local = "x([0-9]+)", .remote = "/r/$1" },
            },
        }},
        .input = "y42",
    },
    // Regex full-match semantics.
    .{
        .desc = "regex: full match succeeds",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "/api/([0-9]+)/info", .remote = "/info/$1" }} }},
        .input = "/api/123/info",
        .expected = .{ .host = "https://e.com", .path = "/info/123" },
    },
    .{
        .desc = "regex: leading extra char is a non-match",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "/api/([0-9]+)/info", .remote = "/info/$1" }} }},
        .input = "/xapi/123/info",
    },
    .{
        .desc = "regex: trailing extra char is a non-match",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "/api/([0-9]+)/info", .remote = "/info/$1" }} }},
        .input = "/api/123/infoX",
    },
    // Legacy $0 / $1..$9 syntax.
    .{
        .desc = "regex: $0 substitutes the whole match",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/num/$0" }} }},
        .input = "42",
        .expected = .{ .host = "https://e.com", .path = "/num/42" },
    },
    .{
        .desc = "regex: single-digit groups $1 and $2",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9])-([0-9])", .remote = "/p/$1/$2" }} }},
        .input = "3-4",
        .expected = .{ .host = "https://e.com", .path = "/p/3/4" },
    },
    .{
        .desc = "regex: $9 beyond the group count is literal",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/$1/$9" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/7/$9" },
    },
    .{
        .desc = "regex: $ not followed by a digit is literal",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/$x/$1" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/$x/7" },
    },
    .{
        .desc = "regex: trailing $ is literal",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/$1$" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/7$" },
    },
    // Braced ${N} syntax (N is 0..=999).
    .{
        .desc = "regex: ${0} substitutes the whole match",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/num/${0}" }} }},
        .input = "42",
        .expected = .{ .host = "https://e.com", .path = "/num/42" },
    },
    .{
        .desc = "regex: ${1} references group 1",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/x/${1}" }} }},
        .input = "42",
        .expected = .{ .host = "https://e.com", .path = "/x/42" },
    },
    .{
        .desc = "regex: ${9}-${12} reference groups past the ninth",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = twelveGroupsPattern[0..], .remote = "/g/${9}/h/${10}/${11}/${12}" }} }},
        .input = "1-2-3-4-5-6-7-8-9-10-11-12",
        .expected = .{ .host = "https://e.com", .path = "/g/9/h/10/11/12" },
    },
    .{
        .desc = "regex: ${2} beyond the group count is literal",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/${2}" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/${2}" },
    },
    .{
        .desc = "regex: ${12} beyond the group count is literal",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/q/${12}" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/q/${12}" },
    },
    .{
        .desc = "regex: ${999} references the 999th group",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = dotGroups999Pattern[0..], .remote = "/a/${1}/b/${500}/c/${999}" }} }},
        .input = digits999Input[0..],
        .expected = .{ .host = "https://e.com", .path = "/a/0/b/9/c/8" },
    },
    .{
        .desc = "regex: ${1000} is outside 0..=999 and literal",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/${1000}" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/${1000}" },
    },
    .{
        .desc = "regex: ${} with no digits is literal",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/${}" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/${}" },
    },
    .{
        .desc = "regex: ${x} with a non-digit is literal",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/${x}" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/${x}" },
    },
    .{
        .desc = "regex: ${ 1} with a space is literal",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/${ 1}" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/${ 1}" },
    },
    .{
        .desc = "regex: unclosed ${ is literal",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/${" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/${" },
    },
    // \$ escaping.
    .{
        .desc = "regex: \\$1 is a literal $1",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/\\$1" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/$1" },
    },
    .{
        .desc = "regex: trailing \\$ is a literal $",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/\\$" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/$" },
    },
    .{
        .desc = "regex: \\$ before $1 still substitutes the group",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/\\$$1" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/$7" },
    },
    .{
        .desc = "regex: backslash before a non-dollar is literal",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/p/\\a$1" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/p/\\a7" },
    },
    // Multiple field rewrites of the URL.
    .{
        .desc = "multi-field: reorder",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "/u/([0-9]+)/o/([0-9]+)/s/([0-9]+)", .remote = "/api/${3}/${2}/${1}" }} }},
        .input = "/u/11/o/22/s/33",
        .expected = .{ .host = "https://e.com", .path = "/api/33/22/11" },
    },
    .{
        .desc = "multi-field: repeat a field",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "/x/$1-${1}-$1" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/x/7-7-7" },
    },
    .{
        .desc = "multi-field: adjacent fields without a separator",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9])-([0-9])", .remote = "/x/${1}${2}" }} }},
        .input = "3-4",
        .expected = .{ .host = "https://e.com", .path = "/x/34" },
    },
    .{
        .desc = "multi-field: mixed bare and braced references",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)-([0-9]+)-([0-9]+)", .remote = "/x/$1/${2}-$3" }} }},
        .input = "1-2-3",
        .expected = .{ .host = "https://e.com", .path = "/x/1/2-3" },
    },
    .{
        .desc = "multi-field: shuffle twelve fields",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = twelveGroupsPattern[0..], .remote = "/r/${12}/${11}/${10}/${9}/${8}/${7}/${6}/${5}/${4}/${3}/${2}/${1}" }} }},
        .input = "1-2-3-4-5-6-7-8-9-10-11-12",
        .expected = .{ .host = "https://e.com", .path = "/r/12/11/10/9/8/7/6/5/4/3/2/1" },
    },
    // Normalization of the rendered path.
    .{
        .desc = "normalization: template without a leading slash gains one",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "$1" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/7" },
    },
    .{
        .desc = "normalization: leading slashes collapse to one",
        .upstreams = &.{.{ .host = "https://e.com", .rules = &.{.{ .type = "regex", .local = "([0-9]+)", .remote = "//$1" }} }},
        .input = "7",
        .expected = .{ .host = "https://e.com", .path = "/7" },
    },
};

test "router: rewrite cases" {
    const allocator = std.testing.allocator;
    inline for (rewrite_cases) |c| try check(allocator, c);
}

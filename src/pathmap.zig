const std = @import("std");
const regex_mod = @import("regex");

/// Errors surfaced while building a path mapping (at config load time).
pub const Error = error{
    /// A path rule of a type the proxy does not support.
    InvalidPathType,
    /// A "regex" rule whose `local` does not compile to a valid regular
    /// expression.
    InvalidRegex,
    OutOfMemory,
};

/// Errors surfaced while rewriting a path (at request time).
pub const RewriteError = error{
    /// The regex engine failed to evaluate an already-compiled pattern. This
    /// should not happen for a pattern that compiled cleanly, but the engine
    /// exposes a runtime error path (e.g. a DFA overflow).
    MatchFailed,
    OutOfMemory,
};

/// The reference bundle a path rule receives when the router asks it to rewrite
/// an incoming client path. `allocator` is used for any rewritten remote path
/// the rule produces; `path` is the client path to match and rewrite.
pub const PathCtx = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
};

/// The result of a successful rewrite. `path` is the rewritten upstream path;
/// `owned` is true when `path` was allocated from `ctx.allocator` and must be
/// freed by the caller (the route), and false when `path` borrows the client
/// path (the direct/identity rewrite) and must not be freed.
pub const RewriteResult = struct {
    path: []const u8,
    owned: bool,
};

/// A single path rewrite rule. `local` is matched against the client path and
/// `remote` is the upstream path it maps to.
///
/// The concrete matching/rewrite behavior is supplied by the `rewrite` function
/// pointer, selected at construction time (see `buildPathMapping`). The plain
/// and regex implementations live in this file; a new match type is added by
/// supplying another `rewrite` implementation here and recognizing its type
/// string in `buildPathMapping`.
pub const PathMapping = struct {
    /// Match type, e.g. "plain" or "regex".
    @"type": []const u8,
    /// The client-facing pattern: a literal prefix for "plain", a regular
    /// expression for "regex".
    local: []const u8,
    /// The upstream path the matched client path maps to. For "regex" this may
    /// reference capture groups with `$1`, `$2`, ... (`$0` is the whole match).
    remote: []const u8,

    /// Rewrite an incoming client path (`ctx.path`) to the upstream path.
    /// Returns null when this rule does not match the path; otherwise a
    /// `RewriteResult` carrying the rewritten path and whether it is owned.
    rewrite: *const fn (self: *const PathMapping, ctx: PathCtx) RewriteError!?RewriteResult,
    /// Release any per-rule state the rule allocated outside the owning
    /// allocator. `null` for rules that own nothing extra.
    deinit: ?*const fn (self: *const PathMapping) void,
    /// Per-implementation state (e.g. the compiled regex engine). `null` for
    /// stateless rules such as "plain".
    data: ?*const anyopaque,
    /// The allocator that owns `data` (and any per-rule state), used to release
    /// it in `deinit`.
    data_allocator: std.mem.Allocator,
};

/// Per-rule state for a "regex" rule: the compiled engine plus the allocator it
/// was compiled with (which also owns the engine's internal allocations).
const RegexData = struct {
    engine: regex_mod.Regex,
    allocator: std.mem.Allocator,
};

/// True when a pattern is the "root": absent (blank) or the bare "/". As a
/// `local` this matches any path; as a `remote` it maps to the upstream origin.
fn isRoot(s: []const u8) bool {
    return s.len == 0 or (s.len == 1 and s[0] == '/');
}

/// Build a path mapping of the given type from its `local`/`remote` pattern
/// strings. This is the single construction point: it validates the type and,
/// for "regex", compiles the `local` pattern so a malformed regex fails here
/// (at config load) with an actionable error rather than at request time.
///
/// For "regex" the compiled engine and its payload are allocated from
/// `allocator` (the config arena in practice), so they are reclaimed together
/// with the rest of the config.
pub fn buildPathMapping(
    allocator: std.mem.Allocator,
    @"type": []const u8,
    local: []const u8,
    remote: []const u8,
) Error!PathMapping {
    if (std.mem.eql(u8, @"type", "plain")) {
        // An all-root rule (local and remote both absent or "/") is the
        // identity mapping; give it its own allocation-free code path.
        const rewrite: *const fn (*const PathMapping, PathCtx) RewriteError!?RewriteResult =
            if (isRoot(local) and isRoot(remote)) directRewrite else plainRewrite;
        return PathMapping{
            .@"type" = @"type",
            .local = local,
            .remote = remote,
            .rewrite = rewrite,
            .deinit = null,
            .data = null,
            .data_allocator = allocator,
        };
    } else if (std.mem.eql(u8, @"type", "regex")) {
        const data = try allocator.create(RegexData);
        errdefer allocator.destroy(data);
        data.engine = regex_mod.Regex.compile(allocator, local) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return Error.InvalidRegex,
        };
        data.allocator = allocator;
        return PathMapping{
            .@"type" = @"type",
            .local = local,
            .remote = remote,
            .rewrite = regexRewrite,
            .deinit = regexDeinit,
            .data = data,
            .data_allocator = allocator,
        };
    } else {
        return Error.InvalidPathType;
    }
}

/// "direct" rewrite: the identity mapping, selected when both `local` and
/// `remote` are root (absent or "/"). The client path is already a clean
/// absolute path, so it is forwarded unchanged. It matches every path and
/// borrows it (no allocation), so the route does not own the returned path.
fn directRewrite(self: *const PathMapping, ctx: PathCtx) RewriteError!?RewriteResult {
    _ = self;
    return .{ .path = ctx.path, .owned = false };
}

/// "plain" rewrite: a strict literal prefix match. On a match, the client
/// remainder is spliced under the `remote` prefix into a clean absolute path.
/// The identity case (both `local` and `remote` root) is handled by
/// `directRewrite`, so plain rewriting always involves a real prefix or a
/// non-root remote.
fn plainRewrite(self: *const PathMapping, ctx: PathCtx) RewriteError!?RewriteResult {
    const path = ctx.path;
    if (!std.mem.startsWith(u8, path, self.local)) return null;
    const rest = path[self.local.len ..];
    const spliced = try splicedPath(ctx.allocator, self.remote, rest);
    return .{ .path = spliced, .owned = true };
}

/// "regex" rewrite: the `local` pattern must match the ENTIRE client path (a
/// full match; a partial match is a non-match). On a match, the `remote`
/// template is rendered with `$0`/`$1`/... substitutions from the match and
/// normalized to a clean absolute path.
fn regexRewrite(self: *const PathMapping, ctx: PathCtx) RewriteError!?RewriteResult {
    // A regex rule always carries its compiled engine (set in buildPathMapping).
    if (self.data) |d| {
        const data: *const RegexData = @alignCast(@ptrCast(d));
        const opt = data.engine.find(ctx.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return RewriteError.MatchFailed,
        };
        if (opt) |match| {
            var m = match;
            // The engine allocates `m.captures` from its own allocator (the
            // config arena), so it must be released with that allocator, not
            // the per-request `ctx.allocator`.
            defer m.deinit(data.allocator);
            if (m.start != 0 or m.end != ctx.path.len) return null; // full match only
            const replaced = try applyReplacement(ctx.allocator, self.remote, m);
            defer ctx.allocator.free(replaced);
            const normalized = try normalizeRemote(ctx.allocator, replaced);
            return .{ .path = normalized, .owned = true };
        } else {
            return null;
        }
    } else {
        return RewriteError.MatchFailed; // unreachable: invariant violated
    }
}

/// Release a "regex" rule's state: the compiled engine (from its allocator) and
/// the payload block. Only meaningful when the rule was built from a non-arena
/// allocator; config-built rules are reclaimed by the arena instead.
fn regexDeinit(self: *const PathMapping) void {
    if (self.data) |d| {
        const data: *const RegexData = @alignCast(@ptrCast(d));
        const engine = @as(*regex_mod.Regex, @constCast(&data.engine));
        engine.deinit();
        self.data_allocator.destroy(@constCast(data));
    }
}

/// Build the normalized upstream path for a plain route: the base prefix and
/// the client remainder joined into a clean absolute path. A base of `""`,
/// `"/"`, or empty is the upstream origin (root). The result always starts with
/// a single `"/"` (or is `"/"` for the bare root) and never doubles the slash
/// at the join, so any mix of root base and slash-bearing remainder splices
/// correctly. The returned slice is allocated from `allocator`.
fn splicedPath(allocator: std.mem.Allocator, remote_prefix: []const u8, rest: []const u8) std.mem.Allocator.Error![]u8 {
    var b = remote_prefix;
    while (b.len > 1 and b[b.len - 1] == '/') b = b[0 .. b.len - 1];
    const root = b.len == 0 or b.len == 1; // "", "/", or a single "/"
    var r = rest;
    while (r.len > 0 and r[0] == '/') r = r[1..];

    if (root) {
        if (r.len == 0) return std.fmt.allocPrint(allocator, "/", .{});
        return std.fmt.allocPrint(allocator, "/{s}", .{ r });
    }
    if (r.len == 0) return std.fmt.allocPrint(allocator, "{s}", .{ b });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ b, r });
}

/// Render a `remote` template against a match, substituting `$0` (the whole
/// match) and `$1`/`$2`/... (capture groups, `captures[n-1]`). A `$` not
/// followed by a digit, or a reference to a group that does not exist, is
/// emitted literally. The returned slice is allocated from `allocator`.
fn applyReplacement(allocator: std.mem.Allocator, template: []const u8, match: regex_mod.Match) RewriteError![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        const c = template[i];
        if (c == '$' and i + 1 < template.len) {
            const d = template[i + 1];
            if (d >= '0' and d <= '9') {
                const n = d - '0';
                if (n == 0) {
                    try out.appendSlice(match.slice);
                } else {
                    const idx = n - 1;
                    if (idx < match.captures.len) {
                        try out.appendSlice(match.captures[idx]);
                    } else {
                        try out.appendSlice(template[i .. i + 2]);
                    }
                }
                i += 1;
                continue;
            }
        }
        try out.append(c);
    }
    return out.toOwnedSlice();
}

/// Canonicalize a rewritten path to a clean absolute path: a single leading
/// `"/"`, or `"/"` when the path is empty. The returned slice is allocated
/// from `allocator`.
fn normalizeRemote(allocator: std.mem.Allocator, s: []const u8) RewriteError![]u8 {
    var r = s;
    while (r.len > 0 and r[0] == '/') r = r[1..];
    if (r.len == 0) return std.fmt.allocPrint(allocator, "/", .{});
    return std.fmt.allocPrint(allocator, "/{s}", .{ r });
}

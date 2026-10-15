const std = @import("std");
const config_mod = @import("config");

/// Routes a client request path to an upstream and rewrites the path.
///
/// Matching is a plain strict-prefix match over the configured path rules.
/// The first rule that matches (upstream order, then rule order) wins. If no
/// rule matches, the first upstream configured with no rules acts as a
/// catch-all passthrough. Returns null when nothing matches and there is no
/// catch-all.
///
/// The route reports the rewrite as two segments (`remote_prefix` + `rest`)
/// rather than an allocated string, so the forward layer can splice them into
/// the upstream URL alongside its own allocations.
pub const Router = struct {
    const Self = @This();

    upstreams: []const config_mod.Upstream,

    pub const Route = struct {
        /// The upstream to forward to. Valid for as long as the config lives.
        upstream: *const config_mod.Upstream,
        /// Upstream path prefix to place before the client path remainder.
        remote_prefix: []const u8,
        /// The client path with the matched local prefix removed.
        rest: []const u8,
    };

    pub fn init(upstreams: []const config_mod.Upstream) Self {
        return .{ .upstreams = upstreams };
    }

    pub fn resolve(self: *const Self, path: []const u8) ?Route {
        for (self.upstreams, 0..) |_, i| {
            const u = self.upstreams[i];
            for (u.path) |p| {
                if (!ruleMatches(p, path)) continue;
                return .{
                    .upstream = &self.upstreams[i],
                    .remote_prefix = p.remote,
                    .rest = path[p.local.len ..],
                };
            }
        }
        for (self.upstreams, 0..) |_, i| {
            if (self.upstreams[i].path.len == 0) {
                return .{
                    .upstream = &self.upstreams[i],
                    .remote_prefix = "",
                    .rest = path,
                };
            }
        }
        return null;
    }

    /// Match one rule against the incoming path. The `"plain"` type is a strict
    /// starts-with (prefix) match. Any other type is rejected at config
    /// validation and therefore cannot reach the resolver, so it never matches.
    fn ruleMatches(p: config_mod.PathMapping, path: []const u8) bool {
        return std.mem.eql(u8, p.@"type", "plain") and std.mem.startsWith(u8, path, p.local);
    }

    /// Build the normalized upstream path for a route: the base prefix and the
    /// client remainder joined into a clean absolute path. A base of `""`, `"/"`,
    /// or empty is the upstream origin (root). The result always starts with a
    /// single `"/"` (or is `"/"` for the bare root) and never doubles the slash
    /// at the join, so any mix of root base and slash-bearing remainder splices
    /// correctly. The returned slice is allocated from `allocator`.
    pub fn splicedPath(allocator: std.mem.Allocator, route: Route) ![]u8 {
        var b = route.remote_prefix;
        while (b.len > 1 and b[b.len - 1] == '/') b = b[0 .. b.len - 1];
        const root = b.len == 0 or b.len == 1; // "", "/", or a single "/"
        var r = route.rest;
        while (r.len > 0 and r[0] == '/') r = r[1..];

        if (root) {
            if (r.len == 0) return std.fmt.allocPrint(allocator, "/", .{});
            return std.fmt.allocPrint(allocator, "/{s}", .{ r });
        }
        if (r.len == 0) return std.fmt.allocPrint(allocator, "{s}", .{ b });
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ b, r });
    }
};

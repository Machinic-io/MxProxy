const std = @import("std");
const config_mod = @import("config");
const pathmap_mod = @import("pathmap");

/// Routes a client request path to an upstream and rewrites the path.
///
/// Matching is delegated to each rule's `PathMapping` implementation (plain is
/// a strict prefix match, regex a full-match pattern rewrite). The first rule
/// that matches (upstream order, then rule order) wins. If no rule matches, the
/// first upstream configured with no rules acts as a catch-all passthrough.
/// Returns null when nothing matches and there is no catch-all.
///
/// The resolved route reports the rewritten upstream path (`remote_path`) as an
/// already-normalized absolute path, so the forward layer splices it onto the
/// upstream host directly.
pub const Router = struct {
    const Self = @This();

    upstreams: []const config_mod.Upstream,

    pub const Route = struct {
        /// The upstream to forward to. Valid for as long as the config lives.
        upstream: *const config_mod.Upstream,
        /// The rewritten, normalized upstream path (always a clean absolute
        /// path). Owned by the route when `owns_remote_path` is true.
        remote_path: []const u8,
        /// Allocator that owns `remote_path` (used by `deinit`).
        allocator: std.mem.Allocator,
        /// True when `remote_path` was allocated by the rule and owned by the
        /// route; false when it borrows the client path (the catch-all and the
        /// direct/identity rewrite).
        owns_remote_path: bool,

        /// Release the route's resources (frees `remote_path` when owned).
        pub fn deinit(self: *const Route) void {
            if (self.owns_remote_path) self.allocator.free(self.remote_path);
        }
    };

    pub fn init(upstreams: []const config_mod.Upstream) Self {
        return .{ .upstreams = upstreams };
    }

    /// Resolve `path` to a route, dispatching each rule's rewrite. `allocator`
    /// backs any rewritten path a rule produces (freed by `Route.deinit`).
    /// Returns null when no rule matches and there is no catch-all.
    pub fn resolve(self: *const Self, allocator: std.mem.Allocator, path: []const u8) anyerror!?Route {
        const ctx = pathmap_mod.PathCtx{ .allocator = allocator, .path = path };
        for (self.upstreams, 0..) |_, i| {
            const u = self.upstreams[i];
            for (u.path) |p| {
                if (try p.rewrite(&p, ctx)) |result| {
                    return .{
                        .upstream = &self.upstreams[i],
                        .remote_path = result.path,
                        .allocator = allocator,
                        .owns_remote_path = result.owned,
                    };
                }
            }
        }
        for (self.upstreams, 0..) |_, i| {
            if (self.upstreams[i].path.len == 0) {
                return .{
                    .upstream = &self.upstreams[i],
                    .remote_path = path,
                    .allocator = allocator,
                    .owns_remote_path = false,
                };
            }
        }
        return null;
    }
};

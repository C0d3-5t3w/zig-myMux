const std = @import("std");
const testing = std.testing;

pub const router = @import("router.zig");
pub const route = @import("route.zig");
pub const middleware = @import("middleware.zig");
pub const regexp = @import("regexp.zig");

pub const Router = router.Router;
pub const Route = route.Route;
pub const MiddlewareFunc = middleware.MiddlewareFunc;

/// Creates a new router instance
pub fn newRouter(allocator: std.mem.Allocator) !*Router {
    return router.newRouter(allocator);
}

test "basic router creation" {
    const alloc = testing.allocator;
    const r = try newRouter(alloc);
    defer r.deinit();

    try testing.expect(r.routes.items.len == 0);
}

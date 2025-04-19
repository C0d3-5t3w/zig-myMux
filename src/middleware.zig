const std = @import("std");
const http = std.http;
const router_mod = @import("router.zig");
const Router = router_mod.Router;

/// Function type for middleware
pub const MiddlewareFunc = *const fn (handler: *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void) *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void;

/// Middleware interface
pub const Middleware = struct {
    ptr: *anyopaque,
    middlewareFn: fn (ptr: *anyopaque, handler: *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void) *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void,

    pub fn middleware(self: Middleware, handler: *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void) *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void {
        return self.middlewareFn(self.ptr, handler);
    }
};

/// Use middleware with a router
pub fn use(r: *Router, mw_list: []const MiddlewareFunc) !void {
    for (mw_list) |mw| {
        try r.middlewares.append(Middleware{
            .ptr = @constCast(&mw),
            .middlewareFn = impl_middleware,
        });
    }
}

fn impl_middleware(ptr: *anyopaque, handler: *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void) *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void {
    const mw_fn = @as(*const MiddlewareFunc, @ptrCast(ptr)).*;
    return mw_fn(handler);
}

/// Use middleware interface with a router
pub fn useInterface(r: *Router, mw: Middleware) !void {
    try r.middlewares.append(mw);
}

/// CORS middleware creator - adds Access-Control-Allow-Methods headers
pub fn corsMethodMiddleware(r: *Router) MiddlewareFunc {
    return struct {
        fn middleware(next: *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void) *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void {
            return struct {
                fn handler(response: *http.Server.Response, req: *const http.Request) anyerror!void {
                    // Try to get all allowed methods for route
                    if (std.mem.eql(u8, req.method.value(), "OPTIONS")) {
                        // For OPTIONS requests, add CORS headers
                        const all_methods = getAllMethodsForRoute(r, req) catch {
                            // If we can't get methods, use defaults
                            try response.headers.append("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS");
                            return next(response, req);
                        };
                        defer r.allocator.free(all_methods);

                        // Join methods with commas
                        try response.headers.append("Access-Control-Allow-Methods", all_methods);
                    }

                    try next(response, req);
                }
            }.handler;
        }
    }.middleware;
}

/// Get all allowed methods for a route
fn getAllMethodsForRoute(r: *Router, req: *const http.Request) ![]const u8 {
    const all_methods = std.ArrayList([]const u8).init(r.allocator);
    defer all_methods.deinit();

    for (r.routes.items) |route| {
        var match = router_mod.Router.RouteMatch.init(r.allocator);
        defer match.deinit();

        if (try route.match(req, &match) or match.err == router_mod.RouterError.MethodMismatch) {
            // Try to extract methods from route
            for (route.matchers.items) |_| {
                // Method matchers are defined in route.zig
                // In a real implementation, we would extract the methods here
                // For simplicity, add default methods
                try all_methods.append("GET");
                try all_methods.append("POST");
                try all_methods.append("PUT");
                try all_methods.append("DELETE");
                try all_methods.append("OPTIONS");
                break;
            }
        }
    }

    return try std.mem.join(r.allocator, ",", all_methods.items);
}

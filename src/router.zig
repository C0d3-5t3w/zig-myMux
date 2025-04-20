const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const route_mod = @import("route.zig");
const Route = route_mod.Route;
const middleware_mod = @import("middleware.zig");
const MiddlewareFunc = middleware_mod.MiddlewareFunc;
const regexp_mod = @import("regexp.zig");

/// Errors that can occur when routing
pub const RouterError = error{
    MethodMismatch,
    RouteNotFound,
    AllocationFailed,
    InvalidRoute,
};

/// Route configuration options
const RouteConf = struct {
    use_encoded_path: bool = false,
    strict_slash: bool = false,
    skip_clean: bool = false,
    regexp: regexp_mod.RouteRegexpGroup,
    matchers: std.ArrayList(Matcher),
    build_scheme: ?[]const u8 = null,
    build_vars_func: ?BuildVarsFunc = null,

    pub fn init(allocator: Allocator) RouteConf {
        return RouteConf{
            .regexp = regexp_mod.RouteRegexpGroup.init(),
            .matchers = std.ArrayList(Matcher).init(allocator),
        };
    }

    pub fn deinit(self: *RouteConf) void {
        self.regexp.deinit();
        self.matchers.deinit();
        if (self.build_scheme) |_| {
            // Clean up if allocated
        }
    }

    pub fn copy(self: *const RouteConf, allocator: Allocator) !RouteConf {
        const conf = RouteConf.init(allocator);
        conf.use_encoded_path = self.use_encoded_path;
        conf.strict_slash = self.strict_slash;
        conf.skip_clean = self.skip_clean;
        conf.regexp = try self.regexp.copy(allocator);

        for (self.matchers.items) |matcher| {
            try conf.matchers.append(matcher);
        }

        if (self.build_scheme) |scheme| {
            conf.build_scheme = try allocator.dupe(u8, scheme);
        }

        conf.build_vars_func = self.build_vars_func;
        return conf;
    }
};

/// Matcher interface for route matching
pub const Matcher = struct {
    ptr: *anyopaque,
    matchFn: fn (ptr: *anyopaque, req: *const http.Request, match_result: *Router.RouteMatch) bool,

    pub fn match(self: *const Matcher, req: *const http.Request, match_result: *Router.RouteMatch) bool {
        return self.matchFn(self.ptr, req, match_result);
    }
};

/// BuildVarsFunc constructs the route URL variables
pub const BuildVarsFunc = ?fn (vars: std.StringHashMap([]const u8)) std.StringHashMap([]const u8);

/// Router is the main request router and multiplexer
pub const Router = struct {
    allocator: Allocator,
    not_found_handler: ?*const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void = null,
    method_not_allowed_handler: ?*const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void = null,
    routes: std.ArrayList(*Route),
    named_routes: std.StringHashMap(*Route),
    keep_context: bool = false,
    middlewares: std.ArrayList(middleware_mod.Middleware),
    route_conf: RouteConf,

    /// Initialize a new router
    pub fn init(allocator: Allocator) !*Router {
        const self = try allocator.create(Router);
        self.* = Router{
            .allocator = allocator,
            .routes = std.ArrayList(*Route).init(allocator),
            .named_routes = std.StringHashMap(*Route).init(allocator),
            .middlewares = std.ArrayList(middleware_mod.Middleware).init(allocator),
            .route_conf = RouteConf.init(allocator),
        };
        return self;
    }

    /// Free all resources
    pub fn deinit(self: *Router) void {
        for (self.routes.items) |route_item| {
            route_item.deinit();
        }
        self.routes.deinit();
        self.named_routes.deinit();
        self.middlewares.deinit();
        self.route_conf.deinit();
        self.allocator.destroy(self);
    }

    /// Set whether the router should handle strict slash matching
    pub fn strictSlash(self: *Router, value: bool) *Router {
        self.route_conf.strict_slash = value;
        return self;
    }

    /// Set whether the router should skip cleaning paths
    pub fn skipClean(self: *Router, value: bool) *Router {
        self.route_conf.skip_clean = value;
        return self;
    }

    /// Set whether the router should use encoded paths
    pub fn useEncodedPath(self: *Router) *Router {
        self.route_conf.use_encoded_path = true;
        return self;
    }

    /// Create a new route for the router
    pub fn newRoute(self: *Router) !*Route {
        const conf = try self.route_conf.copy(self.allocator);
        const route = try Route.init(self.allocator, &self.named_routes, conf);
        try self.routes.append(route);
        return route;
    }

    /// Register a handler for the given path
    pub fn handle(self: *Router, route_path: []const u8, handler: *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void) !*Route {
        const r = try self.newRoute();
        try r.path(route_path);
        try r.handler(handler);
        return r;
    }

    /// Register a handler function for a path
    pub fn handleFunc(self: *Router, route_path: []const u8, handler_fn: *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void) !*Route {
        return try self.handle(route_path, handler_fn);
    }

    /// Get a route by name
    pub fn getRoute(self: *Router, route_name: []const u8) ?*Route {
        return self.named_routes.get(route_name);
    }

    /// Register a named route
    pub fn name(self: *Router, route_name: []const u8) !*Route {
        const r = try self.newRoute();
        try r.name(route_name);
        return r;
    }

    /// Register a route that matches specific HTTP methods
    pub fn methods(self: *Router, methods_list: []const []const u8) !*Route {
        const r = try self.newRoute();
        try r.methods(methods_list);
        return r;
    }

    /// Register a route with a path
    pub fn path(self: *Router, path_pattern: []const u8) !*Route {
        const r = try self.newRoute();
        try r.path(path_pattern);
        return r;
    }

    /// Register a route with a path prefix
    pub fn pathPrefix(self: *Router, prefix: []const u8) !*Route {
        const r = try self.newRoute();
        try r.pathPrefix(prefix);
        return r;
    }

    /// Add query parameters matching
    pub fn queries(self: *Router, pairs: []const []const u8) !*Route {
        const r = try self.newRoute();
        try r.queries(pairs);
        return r;
    }

    /// Set schemes for the route
    pub fn schemes(self: *Router, scheme_list: []const []const u8) !*Route {
        const r = try self.newRoute();
        try r.schemes(scheme_list);
        return r;
    }

    /// Set build vars function
    pub fn buildVarsFunc(self: *Router, f: BuildVarsFunc) !*Route {
        const r = try self.newRoute();
        try r.buildVarsFunc(f);
        return r;
    }

    /// Add middleware to the router
    pub fn use(self: *Router, mw_list: []const middleware_mod.Middleware) !void {
        try self.middlewares.appendSlice(mw_list);
    }

    /// RouteMatch represents the result of matching a request to a route
    pub const RouteMatch = struct {
        route: ?*Route = null,
        handler: ?*const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void = null,
        vars: std.StringHashMap([]const u8),
        err: ?RouterError = null,

        pub fn init(allocator: Allocator) RouteMatch {
            return RouteMatch{
                .vars = std.StringHashMap([]const u8).init(allocator),
            };
        }

        pub fn deinit(self: *RouteMatch) void {
            var iter = self.vars.iterator();
            while (iter.next()) |entry| {
                self.vars.allocator.free(entry.key_ptr.*);
                self.vars.allocator.free(entry.value_ptr.*);
            }
            self.vars.deinit();
        }
    };

    /// Match a request against the router's routes
    pub fn match(self: *Router, req: *const http.Request, match_result: *RouteMatch) !bool {
        for (self.routes.items) |route| {
            if (try route.match(req, match_result)) {
                if (match_result.err == null) {
                    // Apply middlewares in reverse order
                    var i: usize = self.middlewares.items.len;
                    while (i > 0) {
                        i -= 1;
                        const mw = self.middlewares.items[i];
                        if (match_result.handler) |handler| {
                            match_result.handler = mw.middleware(handler);
                        }
                    }
                }
                return true;
            }
        }

        if (match_result.err == RouterError.MethodMismatch) {
            if (self.method_not_allowed_handler != null) {
                match_result.handler = self.method_not_allowed_handler;
                match_result.err = null;
                return true;
            }
            return false;
        }

        if (self.not_found_handler != null) {
            match_result.handler = self.not_found_handler;
            match_result.err = RouterError.RouteNotFound;
            return true;
        }

        match_result.err = RouterError.RouteNotFound;
        return false;
    }

    /// Handle an HTTP request
    pub fn serveHTTP(self: *Router, response: *http.Server.Response, request: *const http.Request) !void {
        // Clean path if needed
        var req = request.*;
        const req_path = req.target;

        if (!self.route_conf.skip_clean) {
            const clean_path = cleanPath(req_path);
            if (!std.mem.eql(u8, clean_path, req_path)) {
                // Redirect to cleaned path
                try response.headers.append("Location", clean_path);
                response.status = .moved_permanently;
                try response.do();
                return;
            }
        }

        // Try to match a route
        var route_match = RouteMatch.init(self.allocator);
        defer route_match.deinit();
        var handler: ?*const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void = null;

        if (try self.match(&req, &route_match)) {
            handler = route_match.handler;
            // In Go, we would set the variables and route in the request context
            // In Zig, we can't modify the request directly, so we'd need a different approach
        }

        if (handler == null and route_match.err == RouterError.MethodMismatch) {
            response.status = .method_not_allowed;
            try response.do();
            return;
        }

        if (handler == null) {
            response.status = .not_found;
            try response.do();
            return;
        }

        try handler.?(response, &req);
    }

    /// Walk the router tree
    pub const WalkFunc = fn (route: *Route, router: *Router, ancestors: []*Route) anyerror!void;

    pub const WalkError = error{
        SkipRouter,
    };

    pub fn walk(self: *Router, walk_fn: WalkFunc, ancestors: []*Route) anyerror!void {
        for (self.routes.items) |route| {
            const err = walk_fn(route, self, ancestors);
            if (err == WalkError.SkipRouter) {
                continue;
            }
            if (err != null) {
                return err;
            }

            // TODO: Handle subrouters
        }
    }
};

/// Create a new router
pub fn newRouter(allocator: Allocator) !*Router {
    return Router.init(allocator);
}

/// Clean up a path by removing extra slashes and dots
fn cleanPath(path: []const u8) []const u8 {
    if (path.len == 0) {
        return "/";
    }

    // This would be a complete implementation of path cleaning like Go's path.Clean
    // For now we return the original path
    return path;
}

// Helper functions similar to those in Go mux
fn uniqueVars(s1: []const []const u8, s2: []const []const u8) !void {
    for (s1) |v1| {
        for (s2) |v2| {
            if (std.mem.eql(u8, v1, v2)) {
                return error.DuplicatedRouteVariable;
            }
        }
    }
}

fn checkPairs(pairs: []const []const u8) !usize {
    const length = pairs.len;
    if (length % 2 != 0) {
        return error.OddNumberOfParameters;
    }
    return length;
}

fn mapFromPairsToString(allocator: Allocator, pairs: []const []const u8) !std.StringHashMap([]const u8) {
    const length = try checkPairs(pairs);
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer map.deinit();

    var i: usize = 0;
    while (i < length) : (i += 2) {
        const key = try allocator.dupe(u8, pairs[i]);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, pairs[i + 1]);
        errdefer allocator.free(value);
        try map.put(key, value);
    }

    return map;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const uri = std.Uri;
const router_mod = @import("router.zig");
const RouterError = router_mod.RouterError;
const RouteMatch = router_mod.Router.RouteMatch;
const regexp_mod = @import("regexp.zig");
const RegexpType = regexp_mod.regexpType;

/// Route stores information about a Zig HTTP route
pub const Route = struct {
    route_handler: ?*const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void = null,
    build_only: bool = false,
    route_name: ?[]const u8 = null,
    err: ?anyerror = null,
    named_routes: *std.StringHashMap(*Route),
    allocator: std.mem.Allocator,

    // Router configuration (copied from parent)
    use_encoded_path: bool = false,
    strict_slash: bool = false,
    skip_clean: bool = false,

    regexp_group: regexp_mod.routeRegexpGroup,
    matchers: std.ArrayList(*const fn (req: *const http.Request, match: *RouteMatch) bool),
    build_scheme: ?[]const u8 = null,
    build_vars_func: ?router_mod.BuildVarsFunc = null,

    /// Initialize a new route
    pub fn init(allocator: Allocator, named_routes: *std.StringHashMap(*Route), conf: router_mod.RouteConf) !*Route {
        const self = try allocator.create(Route);
        self.* = Route{
            .allocator = allocator,
            .named_routes = named_routes,
            .use_encoded_path = conf.use_encoded_path,
            .strict_slash = conf.strict_slash,
            .skip_clean = conf.skip_clean,
            .regexp_group = regexp_mod.routeRegexpGroup.init(allocator),
            .matchers = std.ArrayList(*const fn (req: *const http.Request, match: *RouteMatch) bool).init(allocator),
            .build_scheme = conf.build_scheme,
            .build_vars_func = conf.build_vars_func,
        };
        return self;
    }

    /// Free all resources
    pub fn deinit(self: *Route) void {
        self.regexp_group.deinit();
        self.matchers.deinit();

        if (self.route_name) |n| {
            self.allocator.free(n);
        }

        if (self.build_scheme) |scheme| {
            self.allocator.free(scheme);
        }

        self.allocator.destroy(self);
    }

    /// Check if the route skips cleaning
    pub fn skipClean(self: *Route) bool {
        return self.skip_clean;
    }

    /// Match a request against this route
    pub fn match(self: *Route, req: *const http.Request, match_result: *RouteMatch) !bool {
        if (self.build_only or self.err != null) {
            return false;
        }

        var match_err: ?RouterError = null;

        for (self.matchers.items) |matcher_fn| {
            if (!matcher_fn(req, match_result)) {
                // Check if it's a method mismatch
                if (match_result.err == RouterError.MethodMismatch) {
                    match_err = RouterError.MethodMismatch;
                    continue;
                }

                // Reset MatchErr to clear a prior method mismatch
                if (match_result.err == RouterError.MethodMismatch) {
                    match_result.err = null;
                }

                // No match found
                return false;
            } else {
                // Match succeeded, clear any prior method mismatch
                if (match_result.err == RouterError.MethodMismatch) {
                    match_result.err = null;
                }
            }
        }

        if (match_err != null) {
            match_result.err = match_err;
            return false;
        }

        if (match_result.err == RouterError.MethodMismatch and self.route_handler != null) {
            // If this route has a handler and there was a method mismatch, use this handler
            match_result.err = null;
            match_result.handler = self.route_handler;
        }

        if (match_result.route == null) {
            match_result.route = self;
        }

        if (match_result.handler == null) {
            match_result.handler = self.route_handler;
        }

        // Let the regexp group extract variables from the URL
        try self.regexp_group.setMatch(req, match_result, self);

        return true;
    }

    /// Get any error in this route
    pub fn getError(self: *Route) ?anyerror {
        return self.err;
    }

    /// Mark the route for build-only usage
    pub fn buildOnly(self: *Route) *Route {
        self.build_only = true;
        return self;
    }

    /// Set the handler for this route
    pub fn handler(self: *Route, handler_fn: *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void) !*Route {
        if (self.err == null) {
            self.route_handler = handler_fn;
        }
        return self;
    }

    /// Set a handler function for this route
    pub fn handlerFunc(self: *Route, f: *const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void) !*Route {
        return try self.handler(f);
    }

    /// Get the handler for this route
    pub fn getHandler(self: *Route) ?*const fn (response: *http.Server.Response, request: *const http.Request) anyerror!void {
        return self.route_handler;
    }

    /// Set the name for this route
    pub fn name(self: *Route, route_name: []const u8) !*Route {
        if (self.route_name != null) {
            return error.RouteAlreadyNamed;
        }

        if (self.err == null) {
            const name_copy = try self.allocator.dupe(u8, route_name);
            self.route_name = name_copy;
            try self.named_routes.put(name_copy, self);
        }

        return self;
    }

    /// Get the name of this route
    pub fn getName(self: *Route) ?[]const u8 {
        return self.route_name;
    }

    /// Add a matcher to this route
    fn addMatcher(self: *Route, matcher_fn: *const fn (req: *const http.Request, match: *RouteMatch) bool) !*Route {
        if (self.err == null) {
            try self.matchers.append(matcher_fn);
        }
        return self;
    }

    /// Add a regexp matcher
    fn addRegexpMatcher(self: *Route, tpl: []const u8, typ: RegexpType) !void {
        if (self.err != null) {
            return self.err.?;
        }

        // For path and prefix types, ensure tpl starts with a slash
        if (typ == .path or typ == .prefix) {
            if (tpl.len > 0 and tpl[0] != '/') {
                self.err = error.PathMustStartWithSlash;
                return self.err.?;
            }

            if (self.regexp_group.path) |path_regexp| {
                // Combine with existing path
                const new_tpl = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ std.mem.trimRight(u8, path_regexp.template, "/"), tpl });
                defer self.allocator.free(new_tpl);
                tpl = new_tpl;
            }
        }

        // Create a new route regexp
        const rr = try regexp_mod.newRouteRegexp(self.allocator, tpl, typ, .{
            .strict_slash = self.strict_slash,
            .use_encoded_path = self.use_encoded_path,
        });

        // Check for variable uniqueness
        for (self.regexp_group.queries.items) |q| {
            try regexp_mod.uniqueVars(rr.varsN, q.varsN);
        }

        // Add to the appropriate category in the regexp group
        if (typ == .host) {
            if (self.regexp_group.path) |path_regexp| {
                try regexp_mod.uniqueVars(rr.varsN, path_regexp.varsN);
            }
            self.regexp_group.host = rr;
        } else {
            if (self.regexp_group.host) |host_regexp| {
                try regexp_mod.uniqueVars(rr.varsN, host_regexp.varsN);
            }

            if (typ == .query) {
                try self.regexp_group.queries.append(rr);
            } else {
                self.regexp_group.path = rr;
            }
        }

        // Add the regexp matcher to the route
        try self.addMatcher(rr.matcherFunc());
    }

    /// Set headers for this route
    pub fn headers(self: *Route, pairs: []const []const u8) !*Route {
        if (self.err == null) {
            const headers_map = try router_mod.mapFromPairsToString(self.allocator, pairs);
            // Create a header matcher and add it
            const matcher_fn = createHeaderMatcher(self.allocator, headers_map);
            try self.addMatcher(matcher_fn);
        }
        return self;
    }

    /// Set the host for this route
    pub fn host(self: *Route, tpl: []const u8) !*Route {
        try self.addRegexpMatcher(tpl, .host);
        return self;
    }

    /// Add a matcher function to this route
    pub fn matcherFunc(self: *Route, f: *const fn (req: *const http.Request, match: *RouteMatch) bool) !*Route {
        return try self.addMatcher(f);
    }

    /// Set the methods for this route
    pub fn methods(self: *Route, method_list: []const []const u8) !*Route {
        if (self.err == null) {
            var method_array = std.ArrayList([]u8).init(self.allocator);
            defer method_array.deinit();

            for (method_list) |method| {
                const upper = try std.ascii.allocUpperString(self.allocator, method);
                try method_array.append(upper);
            }

            // Create a method matcher and add it
            const matcher_fn = createMethodMatcher(self.allocator, method_array.items);
            try self.addMatcher(matcher_fn);
        }
        return self;
    }

    /// Set the path for this route
    pub fn path(self: *Route, tpl: []const u8) !*Route {
        try self.addRegexpMatcher(tpl, .path);
        return self;
    }

    /// Set the path prefix for this route
    pub fn pathPrefix(self: *Route, tpl: []const u8) !*Route {
        try self.addRegexpMatcher(tpl, .prefix);
        return self;
    }

    /// Set query parameters for this route
    pub fn queries(self: *Route, pairs: []const []const u8) !*Route {
        const length = try router_mod.checkPairs(pairs);

        var i: usize = 0;
        while (i < length) : (i += 2) {
            try self.addRegexpMatcher(try std.fmt.allocPrint(self.allocator, "{}={}", .{ pairs[i], pairs[i + 1] }), .query);
            if (self.err != null) return self;
        }

        return self;
    }

    /// Set schemes for this route
    pub fn schemes(self: *Route, scheme_list: []const []const u8) !*Route {
        if (self.err == null) {
            var scheme_array = std.ArrayList([]u8).init(self.allocator);
            defer scheme_array.deinit();

            for (scheme_list) |scheme| {
                const lower = try std.ascii.allocLowerString(self.allocator, scheme);
                try scheme_array.append(lower);
            }

            if (scheme_array.items.len > 0) {
                self.build_scheme = try self.allocator.dupe(u8, scheme_array.items[0]);
            }

            // Create a scheme matcher and add it
            const matcher_fn = createSchemeMatcher(self.allocator, scheme_array.items);
            try self.addMatcher(matcher_fn);
        }
        return self;
    }

    /// Set build vars function for this route
    pub fn buildVarsFunc(self: *Route, f: router_mod.BuildVarsFunc) !*Route {
        if (self.err == null) {
            if (self.build_vars_func) |old| {
                // Chain the functions if there's already one set
                self.build_vars_func = struct {
                    fn chain(vars: std.StringHashMap([]const u8)) std.StringHashMap([]const u8) {
                        return f.?(old.?(vars));
                    }
                }.chain;
            } else {
                self.build_vars_func = f;
            }
        }
        return self;
    }

    /// Create a subrouter
    pub fn subrouter(self: *Route) !*router_mod.Router {
        _ = self; // Mark self as used
        // Implementation depends on router.zig
        return error.NotImplemented;
    }

    // URL generation methods
    pub fn url(self: *Route, pairs: []const []const u8) !uri.Uri {
        if (self.err != null) {
            return self.err.?;
        }

        const values = try self.prepareVars(pairs);
        var result = uri.Uri{
            .scheme = "",
            .username = "",
            .password = "",
            .host = "",
            .port = 0,
            .path = "",
            .query = "",
            .fragment = "",
        };

        // Build the URL components
        if (self.regexp_group.host) |host_regexp| {
            const host_str = try host_regexp.url(values);
            result.host = host_str;

            if (self.build_scheme) |scheme| {
                result.scheme = scheme;
            } else {
                result.scheme = "http";
            }
        }

        if (self.regexp_group.path) |path_regexp| {
            const path_str = try path_regexp.url(values);
            result.path = path_str;
        }

        if (self.regexp_group.queries.items.len > 0) {
            var query_parts = std.ArrayList([]const u8).init(self.allocator);
            defer query_parts.deinit();

            for (self.regexp_group.queries.items) |query_regexp| {
                const query_str = try query_regexp.url(values);
                try query_parts.append(query_str);
            }

            result.query = try std.mem.join(self.allocator, "&", query_parts.items);
        }

        return result;
    }

    /// Prepare variables for URL generation
    fn prepareVars(self: *Route, pairs: []const []const u8) !std.StringHashMap([]const u8) {
        const values = try router_mod.mapFromPairsToString(self.allocator, pairs);
        errdefer {
            var it = values.iterator();
            while (it.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
                self.allocator.free(kv.value_ptr.*);
            }
            values.deinit();
        }

        return self.buildVars(values);
    }

    /// Apply buildVarsFunc to variables
    fn buildVars(self: *Route, vars: std.StringHashMap([]const u8)) !std.StringHashMap([]const u8) {
        if (self.build_vars_func) |f| {
            return f.?(vars);
        }
        return vars;
    }
};

// Helper functions to create matchers

fn createHeaderMatcher(_: Allocator, headers: std.StringHashMap([]const u8)) *const fn (req: *const http.Request, match: *RouteMatch) bool {
    const matcher = struct {
        fn matchHeader(req: *const http.Request, _: *RouteMatch) bool {
            var headers_map = headers;
            var iter = headers_map.iterator();
            while (iter.next()) |entry| {
                const header_value = req.headers.getFirstValue(entry.key_ptr.*) orelse return false;
                if (entry.value_ptr.len > 0 and !std.mem.eql(u8, header_value, entry.value_ptr.*)) {
                    return false;
                }
            }
            return true;
        }
    };
    return &matcher.matchHeader;
}

fn createMethodMatcher(_: Allocator, methods: []const []u8) *const fn (req: *const http.Request, match: *RouteMatch) bool {
    const matcher = struct {
        fn matchMethod(req: *const http.Request, match: *RouteMatch) bool {
            const method = req.method.value();
            for (methods) |m| {
                if (std.mem.eql(u8, method, m)) {
                    return true;
                }
            }
            match.err = RouterError.MethodMismatch;
            return false;
        }
    };
    return &matcher.matchMethod;
}

fn createSchemeMatcher(_: Allocator, schemes: []const []u8) *const fn (req: *const http.Request, match: *RouteMatch) bool {
    const matcher = struct {
        fn matchScheme(req: *const http.Request, _: *RouteMatch) bool {
            var scheme: []const u8 = undefined;
            if (req.headers.contains("X-Forwarded-Proto")) {
                scheme = req.headers.getFirstValue("X-Forwarded-Proto") orelse "http";
            } else if (req.headers.contains("X-Scheme")) {
                scheme = req.headers.getFirstValue("X-Scheme") orelse "http";
            } else {
                scheme = "http"; // Assume HTTP by default
            }

            for (schemes) |s| {
                if (std.mem.eql(u8, scheme, s)) {
                    return true;
                }
            }
            return false;
        }
    };
    return &matcher.matchScheme;
}

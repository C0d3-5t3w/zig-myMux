const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const router_mod = @import("router.zig");
const Route = @import("route.zig").Route;

/// Types of regular expressions for route matching
pub const regexpType = enum {
    path,
    host,
    prefix,
    query,
};

/// Options for route regular expressions
pub const routeRegexpOptions = struct {
    strict_slash: bool = false,
    use_encoded_path: bool = false,
};

/// routeRegexp represents a compiled regex pattern for route matching
pub const routeRegexp = struct {
    allocator: Allocator,
    template: []const u8,
    regexp_type: regexpType,
    options: routeRegexpOptions,
    regexp: []const u8, // In a full implementation, this would be a compiled regex
    reverse: []const u8,
    varsN: [][]const u8, // Variable names
    varsR: [][]const u8, // Variable regexes
    wildcard_host_port: bool = false,

    /// Create a copy of this routeRegexp
    pub fn copy(self: *const routeRegexp, allocator: Allocator) !*routeRegexp {
        var new_regexp = try allocator.create(routeRegexp);
        new_regexp.* = .{
            .allocator = allocator,
            .template = try allocator.dupe(u8, self.template),
            .regexp_type = self.regexp_type,
            .options = self.options,
            .regexp = try allocator.dupe(u8, self.regexp),
            .reverse = try allocator.dupe(u8, self.reverse),
            .varsN = try allocator.alloc([]const u8, self.varsN.len),
            .varsR = try allocator.alloc([]const u8, self.varsR.len),
            .wildcard_host_port = self.wildcard_host_port,
        };

        for (self.varsN, 0..) |varN, i| {
            new_regexp.varsN[i] = try allocator.dupe(u8, varN);
        }

        for (self.varsR, 0..) |varR, i| {
            new_regexp.varsR[i] = try allocator.dupe(u8, varR);
        }

        return new_regexp;
    }

    /// Free resources
    pub fn deinit(self: *routeRegexp) void {
        self.allocator.free(self.template);
        self.allocator.free(self.regexp);
        self.allocator.free(self.reverse);

        for (self.varsN) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.varsN);

        for (self.varsR) |regex| {
            self.allocator.free(regex);
        }
        self.allocator.free(self.varsR);
    }

    /// Match checks if the request matches this regexp
    pub fn match(self: *const routeRegexp, req: *const http.Request) bool {
        if (self.regexp_type == .host) {
            const host = getHost(req);
            // If wildcard_host_port, strip the port if present
            var host_to_match = host;
            if (self.wildcard_host_port) {
                if (std.mem.indexOf(u8, host, ":")) |pos| {
                    host_to_match = host[0..pos];
                }
            }
            // In a full implementation, we'd use self.regexp to match host_to_match
            return std.mem.startsWith(u8, host_to_match, self.template); // Simplified for now
        }

        if (self.regexp_type == .query) {
            return self.matchQueryString(req);
        }

        // For path and prefix types
        const path = req.target;
        if (self.options.use_encoded_path) {
            // Would use URL-encoded path if available
        }

        // In a full implementation, we'd use self.regexp to match the path
        if (self.regexp_type == .path) {
            return std.mem.eql(u8, path, self.template); // Exact match
        } else if (self.regexp_type == .prefix) {
            return std.mem.startsWith(u8, path, self.template); // Prefix match
        }

        return false;
    }

    /// Generate a URL from this regexp
    pub fn url(self: *const routeRegexp, values: std.StringHashMap([]const u8)) ![]const u8 {
        // Simple format: replace {name} with value from map
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        var last_end: usize = 0;

        while (i < self.template.len) : (i += 1) {
            if (i < self.template.len - 1 and self.template[i] == '{') {
                // Add text before the variable
                try result.appendSlice(self.template[last_end..i]);

                const start = i + 1;
                // Find closing brace
                while (i < self.template.len and self.template[i] != '}') : (i += 1) {}

                if (i < self.template.len and self.template[i] == '}') {
                    const var_def = self.template[start..i];
                    // Extract the variable name (before any colon)
                    const var_name = if (std.mem.indexOf(u8, var_def, ":")) |pos|
                        var_def[0..pos]
                    else
                        var_def;

                    // Get the value from the map
                    if (values.get(var_name)) |value| {
                        try result.appendSlice(value);
                    } else {
                        return error.MissingRouteVariable;
                    }

                    last_end = i + 1;
                }
            }
        }

        // Add any remaining text
        if (last_end < self.template.len) {
            try result.appendSlice(self.template[last_end..]);
        }

        return result.toOwnedSlice();
    }

    /// Match query string parameters
    fn matchQueryString(self: *const routeRegexp, req: *const http.Request) bool {
        if (self.regexp_type != .query) {
            return false;
        }

        // Extract key=value from template
        const parts = std.mem.split(u8, self.template, "=");
        const key = parts.next() orelse return false;
        const value = parts.next() orelse "";

        // Check if query has this key-value pair
        if (req.query_string) |query| {
            var query_params = std.mem.split(u8, query, "&");
            while (query_params.next()) |param| {
                var kv = std.mem.split(u8, param, "=");
                const q_key = kv.next() orelse continue;
                const q_val = kv.next() orelse "";

                if (std.mem.eql(u8, q_key, key) and std.mem.eql(u8, q_val, value)) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Create a matcher function for this regexp
    pub fn matcherFunc(self: *routeRegexp) *const fn (req: *const http.Request, match_result: *router_mod.Router.RouteMatch) bool {
        const matcher = struct {
            pub fn matchFunc(req: *const http.Request, match_result: *router_mod.Router.RouteMatch) bool {
                return self.match(req);
            }
        };
        return &matcher.matchFunc;
    }
};

/// Group of regexp routes
pub const routeRegexpGroup = struct {
    host: ?*routeRegexp = null,
    path: ?*routeRegexp = null,
    queries: std.ArrayList(*routeRegexp),

    pub fn init(allocator: Allocator) routeRegexpGroup {
        return .{
            .queries = std.ArrayList(*routeRegexp).init(allocator),
        };
    }

    pub fn deinit(self: *routeRegexpGroup) void {
        if (self.host) |host_regexp| {
            host_regexp.deinit();
        }

        if (self.path) |path_regexp| {
            path_regexp.deinit();
        }

        for (self.queries.items) |query_regexp| {
            query_regexp.deinit();
        }

        self.queries.deinit();
    }

    pub fn copy(self: *const routeRegexpGroup, allocator: Allocator) !routeRegexpGroup {
        var new_group = routeRegexpGroup.init(allocator);

        if (self.host) |host_regexp| {
            new_group.host = try host_regexp.copy(allocator);
        }

        if (self.path) |path_regexp| {
            new_group.path = try path_regexp.copy(allocator);
        }

        for (self.queries.items) |query_regexp| {
            try new_group.queries.append(try query_regexp.copy(allocator));
        }

        return new_group;
    }

    pub fn setMatch(self: *routeRegexpGroup, req: *const http.Request, match_result: *router_mod.Router.RouteMatch, _: *Route) !void {
        // Extract variables from host regexp
        if (self.host) |host_regexp| {
            const host = getHost(req);
            var host_to_match = host;

            if (host_regexp.wildcard_host_port) {
                if (std.mem.indexOf(u8, host, ":")) |pos| {
                    host_to_match = host[0..pos];
                }
            }

            try extractVars(match_result.vars, host_regexp.varsN, host_to_match);
        }

        // Extract variables from path regexp
        if (self.path) |path_regexp| {
            var path = req.target;
            if (path_regexp.options.strict_slash) {
                const p1 = std.mem.endsWith(u8, path, "/");
                const p2 = std.mem.endsWith(u8, path_regexp.template, "/");
                if (p1 != p2) {
                    // Would set up a redirect here
                }
            }

            try extractVars(match_result.vars, path_regexp.varsN, path);
        }

        // Extract variables from query regexps
        for (self.queries.items) |query_regexp| {
            if (req.query_string) |query| {
                try extractVars(match_result.vars, query_regexp.varsN, query);
            }
        }
    }
};

/// Create a new routeRegexp
pub fn newRouteRegexp(allocator: Allocator, tpl: []const u8, typ: regexpType, options: routeRegexpOptions) !*routeRegexp {
    var vars_n = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (vars_n.items) |item| allocator.free(item);
        vars_n.deinit();
    }

    var vars_r = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (vars_r.items) |item| allocator.free(item);
        vars_r.deinit();
    }

    // Parse braces to extract variable names and patterns
    var i: usize = 0;
    const template_parts = std.ArrayList(u8).init(allocator);
    defer template_parts.deinit();

    // Simplified brace parsing
    while (i < tpl.len) : (i += 1) {
        if (i < tpl.len and tpl[i] == '{') {
            const start = i + 1;

            // Find closing brace
            i += 1;
            while (i < tpl.len and tpl[i] != '}') : (i += 1) {}

            if (i < tpl.len and tpl[i] == '}') {
                const var_def = tpl[start..i];

                // Split into name and pattern if there's a colon
                if (std.mem.indexOf(u8, var_def, ":")) |colon_pos| {
                    const name = var_def[0..colon_pos];
                    const pattern = var_def[colon_pos + 1 ..];

                    try vars_n.append(try allocator.dupe(u8, name));
                    try vars_r.append(try allocator.dupe(u8, pattern));
                } else {
                    try vars_n.append(try allocator.dupe(u8, var_def));
                    const default_pattern = switch (typ) {
                        .path => "[^/]+",
                        .host => "[^.]+",
                        .query, .prefix => ".*",
                    };
                    try vars_r.append(try allocator.dupe(u8, default_pattern));
                }
            }
        }
    }

    // Create the routeRegexp
    const self = try allocator.create(routeRegexp);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .template = try allocator.dupe(u8, tpl),
        .regexp_type = typ,
        .options = options,
        .regexp = try allocator.dupe(u8, ""), // Would be a compiled regex in a full implementation
        .reverse = try allocator.dupe(u8, tpl), // Simplified reverse template
        .varsN = try vars_n.toOwnedSlice(),
        .varsR = try vars_r.toOwnedSlice(),
        .wildcard_host_port = typ == .host and !std.mem.containsAtLeast(u8, tpl, 1, ":"),
    };

    return self;
}

/// Check if variables are unique between two sets
pub fn uniqueVars(vars1: []const []const u8, vars2: []const []const u8) !void {
    for (vars1) |v1| {
        for (vars2) |v2| {
            if (std.mem.eql(u8, v1, v2)) {
                return error.DuplicatedRouteVariable;
            }
        }
    }
}

/// Extract host from request
fn getHost(req: *const http.Request) []const u8 {
    // Get host from request
    return req.headers.getFirstValue("Host") orelse "";
}

/// Extract variables from a string based on regexp
fn extractVars(vars_map: std.StringHashMap([]const u8), var_names: []const []const u8) !void {
    // Simplified variable extraction
    // In a real implementation, we'd use the regexp to extract values

    for (var_names) |name| {
        // For simplicity, just store the input as the value
        // In a real implementation, we'd extract the specific part
        try vars_map.put(try vars_map.allocator.dupe(u8, name), try vars_map.allocator.dupe(u8, input));
    }
}

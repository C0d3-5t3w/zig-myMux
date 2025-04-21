//  * zig-myMux Documentation
//  *
//  * This document provides an overview of the zig-myMux library, its core components,
//  * and how to integrate it into your Zig projects.
//  *
//  * ## Overview
//  *
//  * zig-myMux is an HTTP request router and multiplexer for Zig, inspired by Go's gorilla/mux.
//  * It allows you to define routes with various matching criteria (path, methods, headers, etc.)
//  * and associate them with handler functions.
//  *
//  * ## Core Components
//  *
//  * ### 1. `Router` (`router.zig`)
//  *
//  * The main entry point for routing. It holds the collection of defined routes and handles
//  * matching incoming requests to the appropriate route handler.
//  *
//  * - **`newRouter(allocator: std.mem.Allocator) !*Router`**: Creates a new Router instance.
//  * - **`serveHTTP(response: *std.http.Server.Response, request: *std.http.Request) !void`**:
//  *   The primary method to handle incoming HTTP requests. It matches the request against
//  *   registered routes and invokes the corresponding handler or a default handler
//  *   (Not Found, Method Not Allowed). This is typically used as the handler function
//  *   for `std.http.Server`.
//  * - **`handle(path: []const u8, handler: HandlerFunc) !*Route`**: Registers a new route
//  *   that matches the given path and associates it with the provided handler function.
//  *   Returns the newly created Route for further configuration.
//  * - **`handleFunc(path: []const u8, handler: HandlerFunc) !*Route`**: Alias for `handle`.
//  * - **`newRoute() !*Route`**: Creates a new, empty Route associated with the router.
//  *   You then use the Route's methods to configure it.
//  * - **`methods(methods: []const []const u8) !*Route`**: Creates a new route that matches
//  *   only the specified HTTP methods.
//  * - **`path(tpl: []const u8) !*Route`**: Creates a new route that matches the exact path template.
//  *   Supports variables like `/users/{id}`.
//  * - **`pathPrefix(tpl: []const u8) !*Route`**: Creates a new route that matches paths
//  *   starting with the given prefix.
//  * - **`queries(pairs: []const []const u8) !*Route`**: Creates a new route that matches
//  *   requests containing the specified query parameters.
//  * - **`schemes(schemes: []const []const u8) !*Route`**: Creates a new route that matches
//  *   requests with the specified URL schemes (e.g., "http", "https").
//  * - **`name(name: []const u8) !*Route`**: Creates a new, empty route and gives it a name
//  *   for later URL generation using `getRoute`.
//  * - **`getRoute(name: []const u8) ?*Route`**: Retrieves a route previously named using `.name()`.
//  * - **`use(mw: []const Middleware) !void`**: Attaches middleware to the router. Middleware
//  *   will be executed for all matched routes.
//  * - **`strictSlash(value: bool) *Router`**: Configures whether paths should strictly match
//  *   trailing slashes.
//  * - **`skipClean(value: bool) *Router`**: Configures whether the router should skip cleaning
//  *   the request path.
//  * - **`notFoundHandler: ?HandlerFunc`**: Sets a custom handler for requests that don't match any route.
//  * - **`methodNotAllowedHandler: ?HandlerFunc`**: Sets a custom handler for requests that match a route's
//  *   path but not its method(s).
//  *
//  * ### 2. `Route` (`route.zig`)
//  *
//  * Represents a single route definition. Routes are typically created via `Router` methods
//  * (`handle`, `path`, `methods`, etc.) and configured using chained method calls.
//  *
//  * - **`handler(handler: HandlerFunc) !*Route`**: Sets the handler function for this route.
//  * - **`handlerFunc(handler: HandlerFunc) !*Route`**: Alias for `handler`.
//  * - **`methods(methods: []const []const u8) !*Route`**: Adds HTTP method matching criteria.
//  * - **`path(tpl: []const u8) !*Route`**: Adds path matching criteria.
//  * - **`pathPrefix(tpl: []const u8) !*Route`**: Adds path prefix matching criteria.
//  * - **`queries(pairs: []const []const u8) !*Route`**: Adds query parameter matching criteria.
//  * - **`schemes(schemes: []const []const u8) !*Route`**: Adds URL scheme matching criteria.
//  * - **`headers(pairs: []const []const u8) !*Route`**: Adds header matching criteria.
//  * - **`host(tpl: []const u8) !*Route`**: Adds host matching criteria. Supports variables.
//  * - **`name(name: []const u8) !*Route`**: Assigns a name to the route for URL generation.
//  * - **`url(pairs: []const []const u8) !std.Uri`**: Generates a URL for the route, filling in
//  *   variables specified in `pairs`. Requires the route to be named or have host/path patterns.
//  *
//  * ### 3. Middleware (`middleware.zig`)
//  *
//  * Middleware functions wrap handlers to add pre-processing or post-processing logic.
//  *
//  * - **`MiddlewareFunc`**: The type definition for a middleware function:
//  *   `*const fn (handler: HandlerFunc) HandlerFunc`
//  *   It takes the next handler in the chain and returns a new handler that wraps it.
//  * - **`corsMethodMiddleware(router: *Router) MiddlewareFunc`**: A built-in middleware
//  *   that automatically adds the `Access-Control-Allow-Methods` header to OPTIONS requests,
//  *   based on the methods defined for the matched route.
//  *
//  * ## Integration into Your Project
//  *
//  * ### 1. Add as a Dependency
//  *
//  * In your project's `build.zig` file, add `zig-myMux` as a dependency. You can use
//  * Zig's build system package manager features or add it manually.
//  *
//  * **Example using `build.zig.zon` and `build.zig`:**
//  *
//  * a. **`build.zig.zon`**:
//  *    ```zon
//  *    .{
//  *        .name = "your_project_name",
//  *        .version = "0.1.0",
//  *        .dependencies = .{
//  *            .@"zig-mymux" = .{
//  *                .url = "https://github.com/your_github/zig-myMux/archive/main.tar.gz", // Replace with actual URL/path
//  *                .hash = "...", // Replace with the correct hash
//  *            },
//  *        },
//  *        .paths = .{""},
//  *    }
//  *    ```
//  *
//  * b. **`build.zig`**:
//  *    ```zig
//  *    const std = @import("std");
//  *
//  *    pub fn build(b: *std.Build) void {
//  *        // ... standard build setup ...
//  *
//  *        const target = b.standardTargetOptions(.{});
//  *        const optimize = b.standardOptimizeOption(.{});
//  *
//  *        // Fetch the dependency
//  *        const mymux_dep = b.dependency("zig-mymux", .{
//  *             .target = target,
//  *             .optimize = optimize,
//  *        });
//  *
//  *        // Get the module from the dependency
//  *        const mymux_module = mymux_dep.module("zig-mymux"); // Assuming the dependency exposes a module named "zig-mymux"
//  *
//  *        const exe = b.addExecutable(.{
//  *            .name = "your_executable",
//  *            .root_source_file = .{ .path = "src/main.zig" },
//  *            .target = target,
//  *            .optimize = optimize,
//  *        });
//  *
//  *        // Add the module to your executable
//  *        exe.addModule("mymux", mymux_module);
//  *
//  *        // Link standard library, etc.
//  *        b.installArtifact(exe);
//  *
//  *        // ... other build steps ...
//  *    }
//  *    ```
//  *    *(Note: The exact dependency setup might vary based on how `zig-myMux` is packaged.)*
//  *
//  * ### 2. Import and Use in Code
//  *
//  * In your Zig source files (e.g., `src/main.zig`), import the library using the module name
//  * defined in `build.zig`.
//  *
//  * ```zig
//  * const std = @import("std");
//  * const http = std.http;
//  * const mymux = @import("mymux"); // Use the module name from build.zig
//  *
//  * // Define your handler functions
//  * fn handleHome(response: *http.Server.Response, request: *const http.Request) !void {
//  *     _ = request; // Mark as used if not needed
//  *     try response.writer().print("Welcome Home!");
//  *     response.status = .ok;
//  *     try response.do();
//  * }
//  *
//  * fn handleUser(response: *http.Server.Response, request: *const http.Request) !void {
//  *     // Accessing route variables requires context passing or modifying the request,
//  *     // which is more complex in Zig than Go. The current implementation focuses
//  *     // on matching, but variable extraction needs refinement for easy handler access.
//  *     // For now, you might parse the target path again based on the matched route pattern.
//  *     _ = request;
//  *     try response.writer().print("User Profile Page"); // Placeholder
//  *     response.status = .ok;
//  *     try response.do();
//  * }
//  *
//  * pub fn main() !void {
//  *     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//  *     const allocator = gpa.allocator();
//  *     defer _ = gpa.deinit();
//  *
//  *     // 1. Create a router
//  *     const router = try mymux.newRouter(allocator);
//  *     defer router.deinit();
//  *
//  *     // 2. Define routes and handlers
//  *     _ = try router.handleFunc("/", handleHome);
//  *     _ = try router.handleFunc("/users/{id}", handleUser).methods(.{ "GET", "POST" });
//  *
//  *     // 3. (Optional) Add middleware
//  *     // const cors = mymux.middleware.corsMethodMiddleware(router);
//  *     // try router.use(&.{cors}); // Example usage
//  *
//  *     // 4. Create and start the HTTP server
//  *     var server = http.Server.init(allocator, .{ .reuse_address = true });
//  *     defer server.deinit();
//  *
//  *     const address = try std.net.Address.parseIp("127.0.0.1", 8080);
//  *     try server.listen(address);
//  *     std.log.info("Server listening on http://127.0.0.1:8080", .{});
//  *
//  *     while (true) {
//  *         var response = try server.accept(.{
//  *             .allocator = allocator,
//  *             // Pass the router's serveHTTP method as the handler
//  *             .handler = router.serveHTTP,
//  *             .log_requests = true,
//  *         });
//  *         // `serveHTTP` handles the request internally, so we just continue the loop.
//  *         // The response is managed within `serveHTTP` or the specific handler.
//  *         _ = response; // Keep the response object alive until handled if needed, though serveHTTP manages it.
//  *     }
//  * }
//  * ```
//  *
//  * ## Extracting Route Variables
//  *
//  * Accessing variables defined in the path (e.g., `{id}` in `/users/{id}`) within the handler
//  * function is less direct in Zig compared to Go's context approach. The `RouteMatch` struct
//  * (used internally by the router) contains the extracted variables.
//  *
//  * A common pattern to make these accessible would involve:
//  * 1. Modifying `serveHTTP` or creating a wrapper handler.
//  * 2. Performing the match within the wrapper.
//  * 3. Storing the matched variables (`RouteMatch.vars`) in a request-specific context (e.g., a custom struct passed to the handler, or potentially using thread-local storage carefully).
//  * 4. The actual route handler would then access this context.
//  *
//  * The current implementation focuses on the routing logic itself. Integrating variable access
//  * into handlers smoothly is a potential area for future enhancement or requires application-specific
//  * patterns.
//  *

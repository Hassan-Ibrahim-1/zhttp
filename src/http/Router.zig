//! Thread safe HTTP multiplexer

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const http = @import("http.zig");
const Response = http.Response;
const Request = http.Request;
const Handler = http.Handler;

const log = std.log.scoped(.Router);

const Router = @This();

arena: std.heap.ArenaAllocator,
handlers: std.StringHashMap(Handler),
handlers_mu: std.Thread.Mutex,

pub fn init(alloc: Allocator) Router {
    return .{
        .arena = .init(alloc),
        .handlers = .init(alloc),
        .handlers_mu = .{},
    };
}

pub fn deinit(self: *Router) void {
    self.deinitHandlers();
    self.arena.deinit();
}

fn deinitHandlers(self: *Router) void {
    self.handlers_mu.lock();
    defer self.handlers_mu.unlock();

    var iter = self.handlers.valueIterator();
    while (iter.next()) |handler| {
        handler.deinit();
    }
    self.handlers.deinit();
}

/// if the same route is registered twice, only the first one is used
pub fn handle(
    self: *Router,
    route: []const u8,
    handler: Handler,
) void {
    self.tryHandle(route, handler) catch unreachable;
}

pub fn handleFn(
    self: *Router,
    route: []const u8,
    comptime func: *const fn (
        res: *Response,
        req: *const Request,
    ) anyerror!void,
) void {
    self.tryHandleFn(route, func) catch unreachable;
}

pub fn tryHandleFn(
    self: *Router,
    route: []const u8,
    comptime func: *const fn (
        res: *Response,
        req: *const Request,
    ) anyerror!void,
) !void {
    const T = struct {
        fn callHandler(_: ?*anyopaque, res: *Response, req: *const Request) !void {
            return func(res, req);
        }
    };
    try self.tryHandle(route, .{
        .ptr = null,
        .vtable = &.{
            .handle = T.callHandler,
        },
    });
}

/// if the same route is registered twice, only the first one is used
pub fn tryHandle(
    self: *Router,
    route: []const u8,
    handler: Handler,
) Allocator.Error!void {
    const r = try self.arena.allocator().dupe(u8, route);
    self.handlers_mu.lock();
    defer self.handlers_mu.unlock();
    try self.handlers.put(r, handler);
}

pub fn dispatch(self: *Router, res: *Response, req: *const Request) !void {
    const best_route = self.findBestRoute(req) orelse
        return http.notFound(res, req.url.path.str);
    log.info("dispatching to {s}", .{best_route});

    self.handlers_mu.lock();
    defer self.handlers_mu.unlock();

    if (self.handlers.get(best_route)) |handler| {
        return handler.handle(res, req);
    }
}

// FIXME: This is a horrible and inefficient algorithm
fn findBestRoute(self: *Router, req: *const Request) ?[]const u8 {
    var best: ?[]const u8 = null;

    const path = req.url.path.str;

    self.handlers_mu.lock();
    defer self.handlers_mu.unlock();

    var iter = self.handlers.keyIterator();

    while (iter.next()) |route_ptr| {
        const route = route_ptr.*;
        if (std.mem.eql(u8, path, route)) return route;
        const blen = if (best) |b| b.len else 0;
        if (isPrefixOf(route, path) and route.len > blen) {
            best = route;
        }
    }
    return best;
}

// FIXME: This is a horrible and inefficient algorithm
fn isPrefixOf(route: []const u8, requested_path: []const u8) bool {
    if (route[route.len - 1] != '/') return false;
    if (route.len > requested_path.len) return false;
    if (std.mem.eql(u8, route, "/")) return true;

    var route_iter = std.mem.splitScalar(u8, route, '/');
    var path_iter = std.mem.splitScalar(u8, requested_path, '/');
    while (route_iter.next()) |r| {
        const p = path_iter.next() orelse return false;
        if (!std.mem.eql(u8, r, p)) {
            if (route_iter.next() == null) return true;
            return false;
        }
    }
    return true;
}

test findBestRoute {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var router = Router.init(alloc);

    const T = struct {
        fn h(_: *http.Response, _: *const http.Request) !void {}
        fn newReq(ally: Allocator, route: []const u8) Request {
            var req: Request = undefined;
            req.url = http.Url.fromRelative(
                ally,
                route,
                .http11,
                "example.com",
                null,
            ) catch unreachable;
            return req;
        }
    };

    router.handleFn("/", T.h);
    router.handleFn("/static/", T.h);
    router.handleFn("/static/images/", T.h);
    router.handleFn("/index.html", T.h);
    router.handleFn("/api/", T.h);
    router.handleFn("/about", T.h);

    const Test = struct {
        route: []const u8,
        expected: []const u8,
    };
    const tests = [_]Test{
        .{ .route = "/", .expected = "/" },
        .{ .route = "/index.html", .expected = "/index.html" },
        .{ .route = "/static/test.html", .expected = "/static/" },
        .{ .route = "/static", .expected = "/" },
        .{ .route = "/static/images", .expected = "/static/" },
        .{ .route = "/static/images/image.png", .expected = "/static/images/" },
        .{ .route = "/foo", .expected = "/" },
        .{ .route = "/static/images", .expected = "/static/" },
        .{ .route = "/static/images/icons/icon.svg", .expected = "/static/images/" },
        .{ .route = "/static/imagesx", .expected = "/static/" },
        .{ .route = "/staticx", .expected = "/" },
        .{ .route = "/api", .expected = "/" },
        .{ .route = "/api/", .expected = "/api/" },
        .{ .route = "/api/users", .expected = "/api/" },
        .{ .route = "/api/users/123", .expected = "/api/" },
        .{ .route = "/about", .expected = "/about" },
        .{ .route = "/about/team", .expected = "/" },
        .{ .route = "/contact", .expected = "/" },
        .{ .route = "/static/css/main.css", .expected = "/static/" },
        .{ .route = "/static/css", .expected = "/static/" },
        .{ .route = "/static/css/", .expected = "/static/" },
        .{ .route = "/index.htm", .expected = "/" },
        .{ .route = "/index.html.bak", .expected = "/" },
        .{ .route = "/api2", .expected = "/" },
    };
    for (&tests) |*t| {
        const req = T.newReq(alloc, t.route);
        const best = router.findBestRoute(&req).?;
        errdefer {
            std.debug.print("best len: {}\n", .{best.len});
            std.debug.print("exp len: {}\n", .{t.expected.len});
        }
        try std.testing.expect(std.mem.eql(u8, best, t.expected));
    }
}

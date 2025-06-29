const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const http = @import("http.zig");
const Response = http.Response;
const Request = http.Request;

const Router = @This();

pub const HandlerFn = *const fn (*Response, *const Request) anyerror!void;

arena: std.heap.ArenaAllocator,
handlers: std.StringHashMap(HandlerFn),

pub fn init(alloc: Allocator) Router {
    return .{
        .arena = .init(alloc),
        .handlers = .init(alloc),
    };
}

pub fn deinit(self: *Router) void {
    self.handlers.deinit();
    self.arena.deinit();
}

/// if the same route is registered twice, only the first one is used
pub fn handle(
    self: *Router,
    route: []const u8,
    handler: HandlerFn,
) void {
    self.tryHandle(route, handler) catch unreachable;
}

/// if the same route is registered twice, only the first one is used
pub fn tryHandle(
    self: *Router,
    route: []const u8,
    handler: HandlerFn,
) Allocator.Error!void {
    const r = try self.arena.allocator().dupe(u8, route);
    try self.handlers.put(r, handler);
}

pub fn serve(self: *Router, res: *Response, req: *const Request) !void {
    const p = req.url.path().path;
    if (self.handlers.get(p)) |handler| {
        return handler(res, req);
    }
    return notFound(res, p);
}

fn notFound(res: *Response, path: []const u8) !void {
    res.status_code = .not_found;
    try res.headers.put("Content-Type", "text/html");
    res.body = try std.fmt.allocPrint(
        res.arena,
        "<h1>404 - Not Found</h1><p>{s} is not a valid url</p>",
        .{path},
    );
}

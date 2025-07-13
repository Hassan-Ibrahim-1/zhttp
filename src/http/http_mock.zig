const std = @import("std");
const http = @import("http.zig");
const mock = @import("../mock/mock.zig");
const request = mock.request;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.http_mock);

const server_ip = "127.0.0.1";
const server_port = 8080;

const index_html = "<h1>Home</h1>";

const Test = struct {
    server: *http.Server,
    router: *http.Router,
    arena: std.heap.ArenaAllocator,

    fn init(alloc: Allocator) !*Test {
        const ti = try alloc.create(Test);
        ti.arena = std.heap.ArenaAllocator.init(alloc);
        ti.server = try createServer(alloc);
        ti.router = try createRouter(alloc);
        return ti;
    }

    fn start(self: *Test) !void {
        const thread = try self.server.listenInNewThread(self.router);
        thread.detach();
    }

    fn deinit(self: *Test, alloc: Allocator) void {
        self.server.stop() catch |err| {
            log.err("Server failed to stop: {}", .{err});
            @panic("Server failed to stop");
        };
        self.server.stopped_listening.wait();
        destroyServer(alloc, self.server);

        alloc.destroy(self.router);

        self.arena.deinit();
        alloc.destroy(self);
    }
};

pub const tests = struct {
    pub fn testIndex(alloc: Allocator) !void {
        const ti = try Test.init(alloc);
        defer ti.deinit(alloc);

        try ti.router.tryHandleFn("/", page.index);

        try ti.start();

        const body = index_html;
        const expected = try createResponse(
            ti,
            .ok,
            &.{
                contentLength(body),
                .{ "Content-Type", "text/html" },
            },
            body,
        );

        const res = try sendRequest(ti.arena.allocator(), "/");
        try mock.expectEqual(res, expected);
    }
};

fn contentLength(comptime body: []const u8) [2][]const u8 {
    return .{
        "Content-Length", std.fmt.comptimePrint("{}", .{body.len}),
    };
}

fn createResponse(
    ti: *Test,
    status_code: http.Status,
    comptime headers: []const [2][]const u8,
    body: []const u8,
) Allocator.Error!*http.Response {
    const alloc = ti.arena.allocator();

    var headers_map = std.StringHashMap([]const u8).init(alloc);
    for (headers) |header| {
        try headers_map.put(header[0], header[1]);
    }

    const res = try alloc.create(http.Response);
    res.* = http.Response{
        .protocol = .http11,
        .arena = alloc,
        .headers = headers_map,
        .status_code = status_code,
        .body = body,
    };
    return res;
}

fn createServer(alloc: Allocator) !*http.Server {
    const server = try alloc.create(http.Server);
    server.* = try http.Server.init(alloc, server_ip, server_port);
    return server;
}

fn destroyServer(alloc: Allocator, server: *http.Server) void {
    server.close();
    server.deinit();
    alloc.destroy(server);
}

fn createRouter(alloc: Allocator) !*http.Router {
    const router = try alloc.create(http.Router);
    router.* = http.Router.init(alloc);
    return router;
}

const page = struct {
    fn index(res: *http.Response, req: *const http.Request) !void {
        _ = req; // autofix
        res.body = index_html;
        try res.headers.put("Content-Type", "text/html");
    }
};

fn sendRequest(arena: Allocator, path: []const u8) !*http.Response {
    const url = try std.fmt.allocPrint(
        arena,
        "http://localhost:8080{s}",
        .{path},
    );
    defer arena.free(url);
    return request.get(arena, url);
}

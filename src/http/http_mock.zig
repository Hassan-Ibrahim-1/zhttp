const std = @import("std");
const http = @import("http.zig");
const mock = @import("../mock/mock.zig");
const request = mock.request;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.http_mock);

const server_ip = "127.0.0.1";
const server_port = 8080;

const index_html = "<h1>Home</h1>";

pub const tests = struct {
    pub fn testIndex(alloc: Allocator) !void {
        const ti = try startTest(alloc);
        defer stopTest(alloc, ti);

        const res = try sendRequest(ti.arena.allocator(), "/");
        log.info("{}", .{res});
    }
};

const TestInfo = struct {
    server: *http.Server,
    router: *http.Router,
    arena: std.heap.ArenaAllocator,
};

fn startTest(alloc: Allocator) !*TestInfo {
    const ti = try alloc.create(TestInfo);
    ti.arena = std.heap.ArenaAllocator.init(alloc);
    ti.server = try createServer(alloc);
    ti.router = try createRouter(alloc);
    const thread = try ti.server.listenInNewThread(ti.router);
    try thread.setName("server thread");
    thread.detach();
    return ti;
}

pub fn stopTest(alloc: Allocator, ti: *TestInfo) void {
    ti.server.stop();
    // this is a little sketchy
    log.info("stopped listening: {}", .{ti.server.stopped_listening.permits});
    // ti.server.stopped_listening.wait();
    destroyServer(alloc, ti.server);

    destroyRouter(alloc, ti.router);
    ti.arena.deinit();
    alloc.destroy(ti);
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
    try router.tryHandleFn("/", page.index);
    return router;
}

fn destroyRouter(alloc: Allocator, router: *http.Router) void {
    alloc.destroy(router);
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

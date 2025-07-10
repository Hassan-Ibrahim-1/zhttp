const std = @import("std");
const log = std.log;

const http = @import("http/http.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var server = try http.Server.init(alloc, "127.0.0.1", 8080);
    defer {
        server.close();
        server.deinit();
    }

    std.log.info("listening on {}", .{server.address});

    var router = http.Router.init(server.alloc);
    router.handleFn("/", index);

    var fs = try http.FileServer.init("res/", null);

    var sp = http.StripPrefix{
        .prefix = "/res/",
        .underlying = fs.handler(),
    };
    router.handle("/res/", sp.handler());
    router.handleFn("/submit-form", submitForm);
    router.handleFn("/file", file);
    router.handleFn("/lorem", lorem);

    try server.listen(&router);
}

fn index(res: *http.Response, req: *const http.Request) !void {
    const p = req.url.path;
    if (!p.eql("/index.html") and !p.eql("/")) {
        return http.notFound(res, p.str);
    }
    res.status_code = .ok;
    try res.headers.put("Content-Type", "text/html");
    try http.serveFile(res, "res/index.html");
    log.info("served /", .{});
}

fn submitForm(res: *http.Response, req: *const http.Request) !void {
    if (req.method != .post) {
        return http.notFound(res, req.url.path.str);
    }
    try res.headers.put("Content-Type", "application/json");
    res.body = try std.json.stringifyAlloc(
        res.arena,
        .{ .got = req.body, .msg = "hey" },
        .{},
    );
}

fn file(res: *http.Response, req: *const http.Request) !void {
    if (req.method != .post) {
        return http.notFound(res, req.url.path.str);
    }
    try res.headers.put("Content-Type", req.headers.get("Content-Type").?);
    res.body = req.body;
}

fn lorem(res: *http.Response, req: *const http.Request) !void {
    if (req.method != .get) {
        return http.notFound(res, req.url.path.str);
    }
    try res.headers.put("Content-Type", "text/plain");
    try http.serveFile(res, "res/lorem.html");
    log.info("served /lorem.html", .{});
}

test {
    _ = std.testing.refAllDeclsRecursive(@This());
}

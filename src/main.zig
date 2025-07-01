const std = @import("std");

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

    const m = std.heap.MemoryPool(http.Request).init(alloc);
    _ = m; // autofix

    std.log.info("listening on {}", .{server.address});

    var router = http.Router.init(server.alloc);
    router.handleFn("/", index);

    var fs = try http.FileServer.init("res/", null);

    var sp = http.StripPrefix{
        .prefix = "/res/",
        .underlying = fs.handler(),
    };
    router.handle("/res/", sp.handler());

    try server.listen(&router);
}

fn index(res: *http.Response, req: *const http.Request) !void {
    const p = req.url.path();
    if (!p.eql("/index.html") and !p.eql("/")) {
        return http.notFound(res, p.path);
    }
    res.status_code = .ok;
    try res.headers.put("Content-Type", "text/html");
    try http.serveFile(res, "res/index.html");
}

fn submitForm(res: *http.Response, req: *const http.Request) !void {
    _ = res; // autofix
    _ = req; // autofix
}

test {
    _ = std.testing.refAllDeclsRecursive(@This());
}

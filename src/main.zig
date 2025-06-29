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

    std.log.info("listening on {}", .{server.address});

    var router = http.Router.init(server.alloc);
    router.handle("/", index);

    try server.listen(&router);
}

fn index(res: *http.Response, req: *const http.Request) !void {
    _ = req; // autofix
    res.status_code = .ok;
    try res.headers.put("Content-Type", "text/html");
    try http.serveFile(res, "res/index.html");
}

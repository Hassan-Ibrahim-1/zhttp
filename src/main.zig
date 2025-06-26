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

    try server.listen();
}

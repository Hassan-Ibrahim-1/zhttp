const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("../http/http.zig");
const log = std.log.scoped(.mock);

pub const request = @import("request.zig");

pub fn run(alloc: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const res = try request.request(
        arena.allocator(),
        "example.com",
        null,
    );
    log.info("{}", .{res});
}

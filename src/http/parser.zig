const std = @import("std");
const net = std.net;
const posix = std.posix;
const log = std.log.scoped(.Server);
const Allocator = std.mem.Allocator;

pub fn parseHttpRequest(alloc: Allocator, socket: posix.socket_t) !void {
    _ = alloc; // autofix
    _ = socket; // autofix
}

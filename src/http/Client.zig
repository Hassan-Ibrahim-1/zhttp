const std = @import("std");
const net = std.net;
const posix = std.posix;
const log = std.log.scoped(.Client);
const Allocator = std.mem.Allocator;

const http = @import("http.zig");

const Client = @This();

arena: *std.heap.ArenaAllocator,
addr: net.Address,
socket: posix.socket_t,
socket_mu: std.Thread.Mutex = .{},
res: http.Response,
reader: http.HttpReader,
writer: http.HttpWriter,

pub fn init(
    alloc: Allocator,
    addr: net.Address,
    socket: posix.socket_t,
) !Client {
    const timeout = posix.timeval{ .sec = 2, .usec = 500_000 };
    // read timeout
    try posix.setsockopt(
        socket,
        posix.SOL.SOCKET,
        posix.SO.RCVTIMEO,
        &std.mem.toBytes(timeout),
    );

    // write timeout
    try posix.setsockopt(
        socket,
        posix.SOL.SOCKET,
        posix.SO.SNDTIMEO,
        &std.mem.toBytes(timeout),
    );
    var arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = .init(alloc);
    return Client{
        .arena = arena,
        .addr = addr,
        .socket = socket,
        .res = http.Response{
            .arena = arena.allocator(),
            .body = "",
            .headers = .init(arena.allocator()),
            .protocol = .http11,
            .status_code = .ok,
        },
        .socket_mu = .{},
        .reader = http.HttpReader.init(arena.allocator(), socket),
        .writer = .{
            .buf = "",
            .socket = socket,
        },
    };
}

pub fn deinit(self: *Client) void {
    log.info("deinitializing {}", .{self.addr});
    const alloc = self.arena.child_allocator;
    self.arena.deinit();
    alloc.destroy(self.arena);

    self.socket_mu.lock();
    defer self.socket_mu.unlock();
    posix.close(self.socket);
}

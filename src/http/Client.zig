const std = @import("std");
const net = std.net;
const posix = std.posix;
const log = std.log.scoped(.Client);
const Allocator = std.mem.Allocator;

const http = @import("http.zig");

const Client = @This();

addr: net.Address,
socket: posix.socket_t,

pub fn init(
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
    return Client{
        .addr = addr,
        .socket = socket,
    };
}

pub fn deinit(self: *Client) void {
    posix.close(self.socket);
}

pub fn reader(self: *Client, alloc: Allocator) Allocator.Error!http.HttpReader {
    return http.HttpReader.init(alloc, self.socket);
}

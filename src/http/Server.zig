const std = @import("std");
const net = std.net;
const posix = std.posix;
const log = std.log.scoped(.Server);
const Allocator = std.mem.Allocator;

const Server = @This();

alloc: Allocator,
arena: std.heap.ArenaAllocator,
address: std.net.Address,
listener: ?posix.socket_t,

pub fn init(alloc: Allocator, ip: []const u8, port: u16) !Server {
    const addr = try net.Address.parseIp(ip, port);

    return .{
        .alloc = alloc,
        .arena = .init(alloc),
        .address = addr,
        .listener = null,
    };
}

pub fn listen(self: *Server) !void {
    const tpe: u32 = posix.SOCK.STREAM;
    const protocol: u32 = posix.IPPROTO.TCP;
    const listener = try posix.socket(self.address.any.family, tpe, protocol);
    self.listener = listener;
    try posix.setsockopt(
        listener,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );
    try posix.bind(
        listener,
        &self.address.any,
        self.address.getOsSockLen(),
    );
    try posix.listen(listener, 128);

    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Length: 48\r\nConnection: close\r\n\r\n<html><body><h1>Hello, world!</h1></body></html>";

    // var buf: [512]u8 = undefined;
    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);
        const socket = posix.accept(
            listener,
            &client_address.any,
            &client_address_len,
            0,
        ) catch |err| {
            log.err("error accept: {}\n", .{err});
            continue;
        };
        defer posix.close(socket);

        log.info("connected to {}", .{client_address});

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

        const read = try readHttpHeaders(self.alloc, socket);
        defer self.alloc.free(read);
        log.info("recieved\n {s}", .{read});

        writeAll(socket, response) catch |err| {
            log.err("Failed to write to socket: {}", .{err});
        };
    }
}

/// reads from the socket
fn readHttpHeaders(alloc: Allocator, socket: posix.socket_t) ![]u8 {
    var buf: [512]u8 = undefined;
    var ret = std.ArrayList(u8).init(alloc);
    while (true) {
        const read = try posix.read(socket, &buf);
        if (read == 0) {
            return error.Closed;
        }
        if (std.mem.indexOf(u8, &buf, "\r\n\r\n")) |index| {
            try ret.appendSlice(buf[0 .. index + 3]);
            break;
        }
        try ret.appendSlice(buf[0..read]);
    }
    return ret.toOwnedSlice();
}

pub fn close(self: *Server) void {
    if (self.listener) |l| {
        posix.close(l);
        self.listener = null;
    } else {
        log.warn(
            "tried to close a server that isn't listening on any address",
            .{},
        );
    }
}

pub fn deinit(self: *Server) void {
    if (self.listener != null) {
        @panic("Close the server before calling deinit");
    }
    self.arena.deinit();
}

fn writeMessage(socket: posix.socket_t, msg: []const u8) !void {
    try writeAll(socket, msg);
}

fn writeAll(socket: posix.socket_t, msg: []const u8) !void {
    var pos: usize = 0;
    while (pos < msg.len) {
        const written = try posix.write(socket, msg[pos..]);
        if (written == 0) {
            return error.Closed;
        }
        pos += written;
    }
}

fn writeAllVectored(socket: posix.socket_t, vec: []posix.iovec_const) !void {
    var i: usize = 0;
    while (true) {
        var n = try posix.writev(socket, vec[i..]);
        while (n >= vec[i].len) {
            n -= vec[i].len;
            i += 1;
            if (i >= vec.len) return;
        }
        vec[i].base += n;
        vec[i].len -= n;
    }
}

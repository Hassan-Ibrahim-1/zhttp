const std = @import("std");
const net = std.net;
const posix = std.posix;
const log = std.log.scoped(.Server);
const Allocator = std.mem.Allocator;

const http = @import("http.zig");
const Client = http.Client;
const io = http.io;

const Server = @This();

alloc: Allocator,
address: std.net.Address,
host: []const u8,
listener: ?posix.socket_t,
router: *http.Router,
event_loop: io.EventLoop,

pub fn init(alloc: Allocator, host: []const u8, port: u16) !Server {
    const addr = try net.Address.parseIp(host, port);
    return Server{
        .alloc = alloc,
        .host = host,
        .address = addr,
        .listener = null,
        .router = undefined,
        .event_loop = try io.EventLoop.init(),
    };
}

pub fn deinit(self: *Server) void {
    if (self.listener != null) {
        @panic("Close the server before calling deinit");
    }
    self.event_loop.deinit();
    self.router.deinit();
}

pub fn listen(self: *Server, router: *http.Router) !void {
    self.router = router;
    const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
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

    try self.event_loop.addListener(listener);
    defer self.event_loop.removeListener(listener) catch unreachable;

    var mem_pool = std.heap.MemoryPool(Client).init(self.alloc);
    defer mem_pool.deinit();

    while (true) {
        var iter = self.event_loop.wait();
        while (iter.next()) |ev| {
            switch (ev) {
                .accept => {
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
                    const client: *Client = try mem_pool.create();
                    client.* = try .init(self.alloc, client_address, socket);

                    try self.event_loop.newClient(client);

                    self.handleClient(client) catch |err| {
                        log.err("client failed: {}", .{err});
                    };
                },
                else => {
                    log.info("recieved a different event type: {s}", .{@tagName(ev)});
                },
            }
        }
    }
}

fn handleClient(self: *Server, client: *Client) !void {
    defer client.deinit();
    log.info("connected to {}", .{client.addr});

    const alloc = client.arena.allocator();

    const reader = &client.reader;

    const msg = reader.readMessage(self.alloc) catch |err| {
        log.err(
            "failed to read message from {}. reason: {}",
            .{ client.addr, err },
        );
        return err;
    };

    const req = try http.parser.parseRequest(self, msg, alloc);

    // this dispatch should be done in a new thread
    // it should then set the client to write mode
    // and the main thread will write the response to the client
    // where should the response be stored temporarily though?
    try self.router.dispatch(&client.res, &req);
    if (!client.res.headers.contains("Content-Length") and client.res.body.len > 0) {
        const len = try std.fmt.allocPrint(alloc, "{}", .{client.res.body.len});
        try client.res.headers.put("Content-Length", len);
    }

    try validateHeaders(&client.res);

    const res_str = try std.fmt.allocPrint(alloc, "{}", .{client.res});
    try writeAll(client.socket, res_str);
}

fn validateHeaders(res: *const http.Response) !void {
    var iter = res.headers.iterator();
    while (iter.next()) |kv| {
        const k = kv.key_ptr.*;
        const v = kv.value_ptr.*;
        if (!http.parser.isValidHeader(k, v)) {
            log.err("{s}: {s} is not a valid header", .{ k, v });
            return error.InvalidHeader;
        }
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

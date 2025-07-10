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
event_loop_mu: std.Thread.Mutex,

pub fn init(alloc: Allocator, host: []const u8, port: u16) !Server {
    const addr = try net.Address.parseIp(host, port);
    return Server{
        .alloc = alloc,
        .host = host,
        .address = addr,
        .listener = null,
        .router = undefined,
        .event_loop = try io.EventLoop.init(),
        .event_loop_mu = .{},
    };
}

pub fn deinit(self: *Server) void {
    if (self.listener != null) {
        @panic("Close the server before calling deinit");
    }
    self.event_loop.deinit();
    self.router.deinit();
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
        var iter = it: {
            self.event_loop_mu.lock();
            defer self.event_loop_mu.unlock();
            break :it self.event_loop.wait();
        };

        while (iter.next()) |ev| {
            switch (ev) {
                .accept => {
                    var client_address: net.Address = undefined;
                    var client_address_len: posix.socklen_t = @sizeOf(net.Address);
                    const socket = posix.accept(
                        listener,
                        &client_address.any,
                        &client_address_len,
                        posix.SOCK.NONBLOCK,
                    ) catch |err| {
                        log.err("error accept: {}\n", .{err});
                        continue;
                    };
                    const client: *Client = try mem_pool.create();
                    client.* = try .init(self.alloc, client_address, socket);

                    log.info("connected to {}", .{client_address});

                    self.event_loop_mu.lock();
                    defer self.event_loop_mu.unlock();
                    try self.event_loop.newClient(client);
                },
                .read => |client| {
                    const alloc = client.arena.allocator();
                    const reader = &client.reader;

                    const msg = reader.readMessage(alloc) catch |err| switch (err) {
                        error.WouldBlock => continue,
                        else => {
                            log.err(
                                "failed to read message from {}. reason: {}",
                                .{ client.addr, err },
                            );
                            client.deinit();
                            clientError(err);
                            continue;
                        },
                    };

                    const req = try alloc.create(http.Request);
                    // TODO: parser.parseRequest should return a pointer
                    req.* = try http.parser.parseRequest(self, msg, alloc);
                    // dispatch
                },
                .write => |client| {
                    client.writer.write() catch |err| {
                        if (err == error.WouldBlock) {
                            continue;
                        } else clientError(err);
                    };
                    client.deinit();
                },
            }
        }
    }
}

fn dispatchClient(
    self: *Server,
    client: *Client,
    req: *const http.Request,
) void {
    self.router.dispatch(&client.res, req) catch |err| {
        clientDispatchError(req.url.path.str, client.addr, err);
        return;
    };

    const alloc = client.arena.allocator();
    try self.router.dispatch(&client.res, &req);
    if (!client.res.headers.contains("Content-Length") and client.res.body.len > 0) {
        const len = std.fmt.allocPrint(alloc, "{}", .{client.res.body.len}) catch |err| {
            clientDispatchError(req.url.path.str, client.addr, err);
            return;
        };
        client.res.headers.put("Content-Length", len) catch |err| {
            clientDispatchError(req.url.path.str, client.addr, err);
            return;
        };
    }

    validateHeaders(&client.res) catch |err| {
        clientDispatchError(req.url.path.str, client.addr, err);
        return;
    };

    const res_str = std.fmt.allocPrint(alloc, "{}", .{client.res}) catch |err| {
        clientDispatchError(req.url.path.str, client.addr, err);
        return;
    };
    client.writer.buf = res_str;

    self.event_loop_mu.lock();
    defer self.event_loop_mu.unlock();
    self.event_loop.setIoMode(client, .write) catch |err| {
        clientDispatchError(req.url.path.str, client.addr, err);
    };
}

fn clientDispatchError(
    url_path: []const u8,
    client_addr: net.Address,
    err: anyerror,
) void {
    log.err(
        "dispatch to {s} for client {} failed, reason: {}",
        .{ url_path, client_addr, err },
    );
}

fn clientError(err: anyerror) void {
    log.err("client failed: {}", .{err});
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

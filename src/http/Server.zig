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
address: net.Address,
host: []const u8,
listener: ?posix.socket_t,
router: *http.Router,
clients: std.DoublyLinkedList(Client),
node_pool: std.heap.MemoryPool(http.ConnectionNode),

event_loop: io.EventLoop,
event_loop_mu: std.Thread.Mutex,

scheduler: io.Scheduler,

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
        .scheduler = .init(alloc, dispatchClient),
        .node_pool = .init(alloc),
        .clients = .{},
    };
}

pub fn deinit(self: *Server) void {
    if (self.listener != null) {
        @panic("Close the server before calling deinit");
    }
    self.event_loop.deinit();
    self.scheduler.deinit();
    self.router.deinit();
    self.node_pool.deinit();
}

fn clearClients(self: *Server) void {
    while (self.clients.pop()) |n| {
        n.data.deinit();
    }
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

    try self.scheduler.start();
    defer self.scheduler.end();

    defer self.clearClients();

    while (true) {
        var iter = it: {
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
                    const node = try self.node_pool.create();
                    node.data = try .init(self.alloc, client_address, socket);
                    self.clients.append(node);

                    try self.event_loop.newConnectionNode(node);

                    log.info("connected to {}", .{client_address});
                },
                .read => |node| {
                    const client = &node.data;
                    const alloc = client.arena.allocator();
                    const reader = &client.reader;

                    const msg = reader.readMessage(alloc) catch |err| switch (err) {
                        error.WouldBlock => continue,
                        else => {
                            log.err(
                                "failed to read message from {}. reason: {}",
                                .{ client.addr, err },
                            );
                            log.info("{} deinit in read", .{client.addr});
                            try self.removeClient(node);
                            clientError(err);
                            continue;
                        },
                    };

                    const req = try alloc.create(http.Request);
                    // TODO: parser.parseRequest should return a pointer
                    req.* = try http.parser.parseRequest(self, msg, alloc);

                    try self.scheduler.schedule(.{
                        .server = self,
                        .node = node,
                        .req = req,
                    });
                },
                .write => |node| {
                    const client = &node.data;
                    client.writer.write() catch |err| {
                        if (err == error.WouldBlock) {
                            continue;
                        } else clientError(err);
                    };
                    log.info("{} deinit in write", .{client.addr});
                    try self.removeClient(node);
                },
            }
        }
    }
}

fn dispatchClient(
    self: *Server,
    node: *http.ConnectionNode,
    req: *const http.Request,
) void {
    const client = &node.data;

    const alloc = client.arena.allocator();
    self.router.dispatch(&client.res, req) catch |err| {
        clientDispatchError(req.url.path.str, client.addr, err);
        return;
    };
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

    self.event_loop.setIoMode(node, .write) catch |err| {
        clientDispatchError(req.url.path.str, client.addr, err);
    };
}

fn removeClient(self: *Server, node: *http.ConnectionNode) !void {
    try self.scheduler.unscheduleClientTasks(&node.data);
    node.data.deinit();
    self.clients.remove(node);
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

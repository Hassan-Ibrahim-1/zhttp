const std = @import("std");
const net = std.net;
const posix = std.posix;
const log = std.log.scoped(.Server);
const Allocator = std.mem.Allocator;

const http = @import("http.zig");

const Server = @This();

alloc: Allocator,
arena: std.heap.ArenaAllocator,
address: std.net.Address,
host: []const u8,
listener: ?posix.socket_t,

pub fn init(alloc: Allocator, host: []const u8, port: u16) !Server {
    const addr = try net.Address.parseIp(host, port);

    return .{
        .alloc = alloc,
        .arena = .init(alloc),
        .host = host,
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
        var client = try http.Client.init(client_address, socket);
        self.handleClient(&client) catch |err| {
            log.err("client failed: {}", .{err});
        };
    }
}

const response_fmt = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{s}";
const resource_not_found = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n";
fn handleClient(self: *Server, client: *http.Client) !void {
    defer client.deinit();
    log.info("connected to {}", .{client.addr});

    var reader = try client.reader(self.alloc);
    defer reader.deinit();

    const msg = reader.readMessage(self.alloc) catch |err| {
        log.err(
            "failed to read message from {}. reason: {}",
            .{ client.addr, err },
        );
        return err;
    };
    defer self.alloc.free(msg);
    // log.info("recieved\n{s}", .{msg});

    const alloc = self.arena.allocator();
    const req = try http.parser.parseRequest(self, msg);

    var res: []const u8 = undefined;

    switch (req.method) {
        .get => {
            const p = try std.mem.concat(alloc, u8, &.{ "res", req.url.path().path });
            const path = http.Path{ .path = p };
            if (path.exists() and try path.kind() == .file) {
                const f = try std.fs.cwd().readFileAlloc(
                    alloc,
                    path.path,
                    std.math.maxInt(u32),
                );
                res = try std.fmt.allocPrint(alloc, response_fmt, .{ f.len, f });
            } else if (path.eql("res/")) {
                const f = try std.fs.cwd().readFileAlloc(
                    alloc,
                    "res/index.html",
                    std.math.maxInt(u32),
                );
                res = try std.fmt.allocPrint(alloc, response_fmt, .{ f.len, f });
            } else {
                log.info("{s} not found", .{path.path});
                res = resource_not_found;
            }
        },
        .post => {
            log.info("received a POST request", .{});
            if (req.headers.get("Content-Type")) |ty| {
                log.info("Content-Type: {s}", .{ty});
            }
            if (req.headers.get("Content-Length")) |ty| {
                log.info("Content-Length: {s}", .{ty});
            }
            log.info("body length: {}", .{req.body.len});
            log.info("body: {s}", .{req.body});
            const html = "<p>BEBE!</p>";
            res = try std.fmt.allocPrint(alloc, response_fmt, .{ html.len, html });
        },
        else => log.err(
            "can't handle method: {s}",
            .{req.method.str()},
        ),
    }

    writeAll(client.socket, res) catch |err| {
        log.err("Failed to write to socket: {}", .{err});
        return err;
    };
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

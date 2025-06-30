const std = @import("std");
const net = std.net;
const posix = std.posix;
const log = std.log.scoped(.Server);
const Allocator = std.mem.Allocator;

const http = @import("http.zig");

const Server = @This();

alloc: Allocator,
address: std.net.Address,
host: []const u8,
listener: ?posix.socket_t,
router: *http.Router,

pub fn init(alloc: Allocator, host: []const u8, port: u16) !Server {
    const addr = try net.Address.parseIp(host, port);

    return .{
        .alloc = alloc,
        .host = host,
        .address = addr,
        .listener = null,
        .router = undefined,
    };
}

pub fn listen(self: *Server, router: *http.Router) !void {
    self.router = router;
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

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    var reader = try client.reader(self.alloc);
    defer reader.deinit();

    const msg = reader.readMessage(self.alloc) catch |err| {
        log.err(
            "failed to read message from {}. reason: {}",
            .{ client.addr, err },
        );
        return err;
    };

    const req = try http.parser.parseRequest(self, msg, alloc);

    var res: http.Response = undefined;
    res.arena = alloc;
    res.body = "";
    res.headers = .init(alloc);
    try self.router.dispatch(&res, &req);
    if (!res.headers.contains("Content-Length") and res.body.len > 0) {
        const len = try std.fmt.allocPrint(alloc, "{}", .{res.body.len});
        try res.headers.put("Content-Length", len);
    }

    const res_str = try std.fmt.allocPrint(alloc, "{}", .{res});
    try writeAll(client.socket, res_str);
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
    self.router.deinit();
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

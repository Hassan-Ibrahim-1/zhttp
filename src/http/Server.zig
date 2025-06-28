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
        self.handleClient(&client) catch continue;
    }
}

const response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Length: 48\r\nConnection: close\r\n\r\n<html><body><h1>Hello, world!</h1></body></html>";
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
    log.info("recieved\n{s}", .{msg});

    writeAll(client.socket, response) catch |err| {
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

const ParseError = error{
    InvalidHttpRequest,
    InvalidRequestLine,
    InvalidHeaders,
    InvalidBody,
} || Allocator.Error;

fn parseRequest(alloc: Allocator, req: []const u8) ParseError!http.Request {
    if (!std.mem.containsAtLeast(u8, req, 2, "\r\n")) {
        return error.InvalidHttpRequest;
    }
    var lines = std.mem.splitSequence(u8, req, "\r\n");

    const req_line = try parseRequestLine(alloc, lines.next().?);
    // std.debug.print("{any}\n", .{req_line});
    return http.Request{
        .method = req_line.method,
        .url = req_line.url,
        .protocol = req_line.protocol,
        .arena = alloc,
        .body = "",
        .headers = .init(alloc),
    };
}

fn parseRequestLine(
    alloc: Allocator,
    req_line: []const u8,
) ParseError!struct {
    method: http.Method,
    url: []u8,
    protocol: http.Protocol,
} {
    if (!std.mem.containsAtLeast(u8, req_line, 2, " ")) {
        return error.InvalidRequestLine;
    }
    var els = std.mem.splitScalar(u8, req_line, ' ');

    const method = http.Method.from(els.next().?) orelse
        return error.InvalidRequestLine;
    const url = try alloc.dupe(u8, els.next().?);
    const protocol = http.Protocol.from(els.next().?) orelse
        return error.InvalidRequestLine;

    return .{
        .method = method,
        .url = url,
        .protocol = protocol,
    };
}

test "parseRequest" {
    const reqstr = "POST /static/image.png HTTP/1.1\r\nHost: www.example.com\r\nUser-Agent: Mozilla/5.0\r\nAccept: text/html\r\nConnection: close\r\n\r\n";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const req = try parseRequest(alloc, reqstr);

    try std.testing.expect(req.method == .post);
    try std.testing.expect(req.protocol == .http11);
    try std.testing.expect(std.mem.eql(u8, req.url, "/static/image.png"));
}

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.http);

pub const Server = @import("Server.zig");
pub const Client = @import("Client.zig");
pub const Request = @import("Request.zig");

pub const Method = enum {
    get,
    head,
    post,
    put,
    patch,
    delete,
    options,
    connect,

    const m = std.StaticStringMap(Method).initComptime(&.{
        .{ "GET", .get },
        .{ "HEAD", .head },
        .{ "POST", .post },
        .{ "PUT", .put },
        .{ "PATCH", .patch },
        .{ "DELETE", .delete },
        .{ "OPTIONS", .options },
        .{ "CONNECT", .connect },
    });

    pub fn str(self: Method) []const u8 {
        const i = std.mem.indexOfScalar(Method, m.values(), self).?;
        return m.keys()[i];
    }

    pub fn from(s: []const u8) ?Method {
        return m.get(s);
    }
};

pub const Protocol = enum {
    http11,

    const m = std.StaticStringMap(Protocol).initComptime(&.{
        .{ "HTTP/1.1", .http11 },
    });

    pub fn str(self: Protocol) []const u8 {
        const i = std.mem.indexOfScalar(Protocol, m.values(), self).?;
        return m.keys()[i];
    }

    pub fn from(s: []const u8) ?Protocol {
        return m.get(s);
    }
};

pub const HttpReader = struct {
    buf: std.ArrayList(u8),
    pos: usize,
    start: usize,
    socket: posix.socket_t,

    pub fn init(
        alloc: Allocator,
        socket: posix.socket_t,
    ) HttpReader {
        return HttpReader{
            .buf = .init(alloc),
            .pos = 0,
            .start = 0,
            .socket = socket,
        };
    }

    pub fn deinit(self: *HttpReader) void {
        self.buf.deinit();
    }

    pub fn readMessage(self: *HttpReader, alloc: Allocator) ![]u8 {
        if (self.buf.items.len == 0) {
            try self.ensureSpace(512);
        }

        const buf = self.buf.items[0..self.buf.items.len];
        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return alloc.dupe(u8, msg);
            }

            const pos = self.pos;

            const n = try posix.read(self.socket, buf[pos..]);
            if (n == 0) {
                if (self.pos == self.buf.items.len) {
                    try self.ensureSpace(self.buf.capacity * 2);
                    continue;
                }
                return error.Closed;
            }
            self.pos = pos + n;
        }
    }

    /// if null, there is no body
    fn bodyLen(msg: []const u8) std.fmt.ParseIntError!?usize {
        const header = "Content-Type: ";
        const index = std.mem.indexOf(u8, msg, header);
        if (index) |i| {
            const start = i + header.len;
            const end = std.mem.indexOf(u8, msg[start..], "\r\n").?;
            return std.fmt.parseInt(usize, msg[start], msg[start..end]);
        }
        return null;
    }

    fn ensureSpace(self: *HttpReader, cap: usize) !void {
        if (cap <= self.buf.capacity) return;

        const new = cap - self.buf.items.len;
        try self.buf.ensureTotalCapacity(cap);
        self.buf.appendNTimesAssumeCapacity(0, new);
    }

    fn bufferedMessage(self: *HttpReader) !?[]u8 {
        const buf = self.buf.items[0..self.buf.items.len];
        const pos = self.pos;
        const start = self.start;

        std.debug.assert(pos >= start);
        const unprocessed = buf[start..pos];
        const index = std.mem.indexOf(u8, unprocessed, "\r\n\r\n");
        // FIXME: incomplete, should account for an http body
        if (index) |i| {
            self.start += i + 4;
            return buf[start..self.start];
        }
        return null;
    }

    fn extractBody(self: *HttpReader) !void {
        const buf = 
        const len = try bodyLen(msg) orelse return;
        if (len == 0) return;
        posix.read(self.socket, )
    }
};

test "bufferedMessage multiple messages" {
    const alloc = std.testing.allocator;
    const msg =
        "GET /index.html HTTP/1.1\r\nHost: www.example.com\r\nUser-Agent: Mozilla/5.0\r\nAccept: text/html\r\nConnection: close\r\n\r\n";
    var reader = HttpReader{
        .pos = msg.len,
        .start = 0,
        .socket = undefined,
        .buf = .init(alloc),
    };
    var buf = &reader.buf;
    defer buf.deinit();

    try buf.appendSlice(msg);

    var m = try reader.bufferedMessage();
    try std.testing.expect(std.mem.eql(u8, msg, m.?));

    const msg2 =
        "GET /google.html HTTP/1.1\r\nHost: www.google.com\r\nUser-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)\r\nAccept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\nAccept-Language: en-US,en;q=0.5\r\nConnection: keep-alive\r\n\r\n";
    const initial_slice = 10;
    try buf.appendSlice(msg2[0..initial_slice]);
    reader.pos = buf.items.len;
    m = try reader.bufferedMessage();
    try std.testing.expect(m == null);

    try buf.appendSlice(msg2[initial_slice..]);
    reader.pos = buf.items.len;
    m = try reader.bufferedMessage();

    try std.testing.expect(std.mem.eql(u8, m.?, msg2));
}

test "bufferedMessage no body" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    const msg =
        "GET /index.html HTTP/1.1\r\nHost: www.example.com\r\nUser-Agent: Mozilla/5.0\r\nAccept: text/html\r\nConnection: close\r\n\r\n";
    try buf.appendSlice(msg);
    var reader = HttpReader{
        .pos = msg.len,
        .start = 0,
        .socket = undefined,
        .buf = buf,
    };
    const m = try reader.bufferedMessage();
    try std.testing.expect(std.mem.eql(u8, msg, m.?));
}

test "bufferedMessage garbage bytes" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    const msg =
        "GET /index.html HTTP/1.1\r\nHost: www.example.com\r\nUser-Agent: Mozilla/5.0\r\nAccept: text/html\r\nConnection: close\r\n\r\n";
    try buf.appendSlice(msg ++ "jfdlsnvxnvxcvkjsdfkldjs");
    var reader = HttpReader{
        .pos = msg.len,
        .start = 0,
        .socket = undefined,
        .buf = buf,
    };
    const m = try reader.bufferedMessage();
    try std.testing.expect(std.mem.eql(u8, msg, m.?));
}

test "method str" {
    try std.testing.expect(std.mem.eql(u8, Method.get.str(), "GET"));
}

test "method from" {
    try std.testing.expect(Method.from("GET") == .get);
}

test "protocol str" {
    try std.testing.expect(std.mem.eql(u8, Protocol.http11.str(), "HTTP/1.1"));
}

test "protocol from" {
    try std.testing.expect(Protocol.from("HTTP/1.1") == .http11);
}

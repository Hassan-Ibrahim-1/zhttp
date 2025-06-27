const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.http);

pub const Server = @import("Server.zig");
pub const Client = @import("Client.zig");

pub const HttpReader = struct {
    buf: std.ArrayList(u8),
    pos: usize,
    start: usize,
    socket: posix.socket_t,

    pub fn init(
        alloc: Allocator,
        socket: posix.socket_t,
    ) Allocator.Error!HttpReader {
        var buf = std.ArrayList(u8).init(alloc);
        const initial_capacity = 512;
        try buf.ensureTotalCapacity(initial_capacity);
        buf.appendSliceAssumeCapacity("\x00" ** initial_capacity);
        return HttpReader{
            .buf = buf,
            .pos = 0,
            .start = 0,
            .socket = socket,
        };
    }

    pub fn deinit(self: *HttpReader) void {
        self.buf.deinit();
    }

    pub fn readMessage(self: *HttpReader, alloc: Allocator) ![]u8 {
        const buf = self.buf.items[0..self.buf.items.len];
        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return alloc.dupe(u8, msg);
            }

            const pos = self.pos;

            log.info("buf len: {}", .{self.buf.items.len});
            const n = try posix.read(self.socket, buf[pos..]);
            log.info("pos: {}", .{pos});
            if (n == 0) {
                return error.Closed;
            }
            self.pos = pos + n;
        }
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
            const len = (i - self.start) + 4;
            self.start += len;
            return buf[start .. i + 4];
        }
        return null;
    }
};

test "bufferedMessage no body" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    // not using a multiline string literal because it doesn't support escape sequences
    const msg =
        "GET /index.html HTTP/1.1\r\n" ++ "Host: www.example.com\r\n" ++ "User-Agent: Mozilla/5.0\r\n" ++ "Accept: text/html\r\n" ++ "Connection: close\r\n" ++ "\r\n";
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
    // not using a multiline string literal because it doesn't support escape sequences
    const msg =
        "GET /index.html HTTP/1.1\r\n" ++ "Host: www.example.com\r\n" ++ "User-Agent: Mozilla/5.0\r\n" ++ "Accept: text/html\r\n" ++ "Connection: close\r\n" ++ "\r\n";
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

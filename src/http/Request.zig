const std = @import("std");
const Allocator = std.mem.Allocator;

const http = @import("http.zig");

const Request = @This();

method: http.Method,
url: http.Url,
protocol: http.Protocol,
headers: std.StringHashMap([]const u8),
body: []const u8,
arena: Allocator,

pub fn format(
    self: *const Request,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    out_stream: anytype,
) !void {
    _ = options; // autofix
    if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);

    try std.fmt.format(
        out_stream,
        "{s} {s} {s}\r\n",
        .{ self.method.str(), self.url.raw, self.protocol.str() },
    );

    var iter = self.headers.iterator();
    while (iter.next()) |header| {
        const k = header.key_ptr.*;
        const v = header.value_ptr.*;
        try std.fmt.format(out_stream, "{s}: {s}\r\n", .{ k, v });
    }
    try out_stream.writeAll("\r\n");
    try out_stream.writeAll(self.body);
}

test format {
    const alloc = std.testing.allocator;

    var req = Request{
        .method = .get,
        .protocol = .http11,
        .url = .init("http://example.com/index.html"),
        .body = "<p>Hello</p>",
        .arena = undefined,
        .headers = .init(alloc),
    };
    defer req.headers.deinit();
    try req.headers.put("Content-Type", "text/html");
    try req.headers.put("Content-Length", "12");

    const expected = "GET http://example.com/index.html HTTP/1.1\r\nContent-Type: text/html\r\nContent-Length: 12\r\n\r\n<p>Hello</p>";
    const actual = try std.fmt.allocPrint(alloc, "{}", .{req});
    defer alloc.free(actual);
    errdefer std.debug.print("got={s}\n", .{actual});
    try std.testing.expect(std.mem.eql(u8, actual, expected));
}

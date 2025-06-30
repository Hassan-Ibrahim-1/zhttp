const std = @import("std");
const Allocator = std.mem.Allocator;

const http = @import("http.zig");

const Response = @This();

protocol: http.Protocol,
status_code: http.Status,
headers: std.StringHashMap([]const u8),
arena: Allocator,
body: []const u8,

pub fn format(
    self: *const Response,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    out_stream: anytype,
) !void {
    _ = options; // autofix
    if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);

    try std.fmt.format(
        out_stream,
        "{s} {} {s}\r\n",
        .{
            self.protocol.str(),
            @intFromEnum(self.status_code),
            self.status_code.phrase() orelse "Custom Status",
        },
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

    var res = Response{
        .status_code = .not_found,
        .protocol = .http11,
        .body = "Oops",
        .arena = undefined,
        .headers = .init(alloc),
    };
    defer res.headers.deinit();
    try res.headers.put("Connection", "close");
    try res.headers.put("Content-Length", "4");
    try res.headers.put("Content-Type", "text/plain");

    const expected = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 4\r\n\r\nOops";
    const actual = try std.fmt.allocPrint(alloc, "{}", .{res});
    defer alloc.free(actual);
    errdefer std.debug.print("got={s}\n", .{actual});
    try std.testing.expect(std.mem.eql(u8, actual, expected));
}

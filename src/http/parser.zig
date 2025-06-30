const std = @import("std");
const log = std.log.scoped(.Server);
const Allocator = std.mem.Allocator;

const http = @import("http.zig");

pub const ParseError = error{
    InvalidHttpRequest,
    InvalidRequestLine,
    InvalidMethod,
    InvalidUrl,
    InvalidProtocol,
    InvalidHeader,
    InvalidBody,
} || http.UrlParseError;

pub fn parseRequest(server: *http.Server, req: []const u8, arena: Allocator) ParseError!http.Request {
    if (!std.mem.containsAtLeast(u8, req, 2, "\r\n")) {
        return error.InvalidHttpRequest;
    }
    var lines = std.mem.splitSequence(u8, req, "\r\n");

    const req_line = try parseRequestLine(arena, lines.next().?);

    var headers = std.StringHashMap([]const u8).init(arena);

    while (lines.next()) |header| {
        // \r\n\r\n pattern found
        if (header.len == 0) break;
        const kv = try parseHeader(arena, header);
        try headers.put(kv.key, kv.value);
    }

    return http.Request{
        .method = req_line.method,
        .url = try .fromRelative(
            arena,
            req_line.url_raw,
            .http11,
            server.host,
            server.address.getPort(),
        ),
        .protocol = req_line.protocol,
        .arena = arena,
        .body = lines.next() orelse "",
        .headers = headers,
    };
}

pub fn parseRequestLine(
    alloc: Allocator,
    req_line: []const u8,
) ParseError!struct {
    method: http.Method,
    url_raw: []u8,
    protocol: http.Protocol,
} {
    if (!std.mem.containsAtLeast(u8, req_line, 2, " ")) {
        return error.InvalidRequestLine;
    }
    var els = std.mem.splitScalar(u8, req_line, ' ');

    const method = http.Method.from(els.next().?) orelse
        return error.InvalidMethod;
    // FIXME: do basic checks on this url. make sure it is syntactically valid
    const url = try alloc.dupe(u8, els.next().?);
    const protocol = http.Protocol.from(els.next().?) orelse
        return error.InvalidProtocol;

    return .{
        .method = method,
        .url_raw = url,
        .protocol = protocol,
    };
}

pub fn parseHeader(
    alloc: Allocator,
    header: []const u8,
) ParseError!struct { key: []u8, value: []u8 } {
    if (!std.mem.containsAtLeast(u8, header, 1, ": ")) {
        return error.InvalidHeader;
    }
    var s = std.mem.splitSequence(u8, header, ": ");
    // FIXME: make sure the header is syntactially valid
    const key = try alloc.dupe(u8, s.next().?);
    const value = try alloc.dupe(u8, s.next().?);
    return .{
        .key = key,
        .value = value,
    };
}

test parseRequest {
    // GET /static/image.png HTTP/1.1
    // Host: www.example.com
    // User-Agent: Mozilla/5.0
    // Accept: text/html
    // Connection: close
    const expected_headers = comptime std.StaticStringMap([]const u8).initComptime(&.{
        .{ "Host", "www.example.com" },
        .{ "User-Agent", "Mozilla/5.0" },
        .{ "Accept", "text/html" },
        .{ "Connection", "close" },
    });
    const reqstr = "GET /static/image.png HTTP/1.1\r\nHost: www.example.com\r\nUser-Agent: Mozilla/5.0\r\nAccept: text/html\r\nConnection: close\r\n\r\n";

    const host = "127.0.0.1";
    var server = try http.Server.init(std.testing.allocator, host, 8080);

    var arena = std.heap.ArenaAllocator.init(server.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const req = try parseRequest(&server, reqstr, alloc);

    try std.testing.expect(req.method == .get);
    try std.testing.expect(req.protocol == .http11);
    try std.testing.expect(req.url.path().eql("/static/image.png"));

    const headers = &req.headers;
    try std.testing.expect(expected_headers.keys().len == headers.count());

    for (0..expected_headers.keys().len) |i| {
        const expected_key = expected_headers.keys()[i];
        const expected_value = expected_headers.values()[i];

        const actual = headers.get(expected_key).?;
        std.testing.expect(
            std.mem.eql(u8, actual, expected_value),
        ) catch |err| {
            std.debug.print(
                "[{s}] expected={s}, got={s}\n",
                .{ expected_key, expected_value, actual },
            );
            return err;
        };
    }

    try std.testing.expect(req.body.len == 0);
}

test parseRequestLine {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rl = try parseRequestLine(alloc, "GET /index.html HTTP/1.1");
    try std.testing.expect(rl.method == .get);
    try std.testing.expect(rl.protocol == .http11);
    try std.testing.expect(std.mem.eql(u8, rl.url_raw, "/index.html"));

    var rle = parseRequestLine(alloc, "BADMETHOD /test.html HTTP/1.1");
    try std.testing.expectError(error.InvalidMethod, rle);

    rle = parseRequestLine(alloc, "GET /test.html HTTP/2");
    try std.testing.expectError(error.InvalidProtocol, rle);

    rle = parseRequestLine(alloc, "GET/test.html HTTP/1.1");
    try std.testing.expectError(error.InvalidRequestLine, rle);
}

test parseHeader {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const header = try parseHeader(alloc, "Content-Length: 128");
    try std.testing.expect(std.mem.eql(u8, header.key, "Content-Length"));
    try std.testing.expect(std.mem.eql(u8, header.value, "128"));

    const err = parseHeader(alloc, "Host:www.example.com");
    try std.testing.expectError(error.InvalidHeader, err);
}

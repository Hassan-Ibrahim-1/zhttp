const std = @import("std");
const Allocator = std.mem.Allocator;

const http = @import("http.zig");
const debug = http.debug;

const log = std.log.scoped(.Server);

pub const ParseError = error{
    InvalidHttpMessage,
    InvalidRequestLine,
    InvalidStatusLine,
    InvalidStatusCode,
    InvalidMethod,
    InvalidUrl,
    InvalidProtocol,
    InvalidHeader,
    InvalidBody,
} || http.UrlParseError || std.fmt.ParseIntError;

pub fn parseRequest(
    server: *http.Server,
    req: []const u8,
    arena: Allocator,
) ParseError!http.Request {
    if (!std.mem.containsAtLeast(u8, req, 2, "\r\n")) {
        return error.InvalidHttpMessage;
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

    const body =
        if (lines.next()) |b| try arena.dupe(u8, b) else "";

    return http.Request{
        .method = req_line.method,
        .url = url: {
            if (http.Url.isRelative(req_line.url_raw)) {
                break :url try http.Url.fromRelative(
                    arena,
                    req_line.url_raw,
                    .http11,
                    server.host,
                    server.address.getPort(),
                );
            } else {
                break :url http.Url.init(req_line.url_raw);
            }
        },
        .protocol = req_line.protocol,
        .arena = arena,
        .body = body,
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

pub fn isValidHeader(key: []const u8, val: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |ch| {
        if (!validHeaderKeyChar(ch)) return false;
    }
    for (val) |ch| {
        if (!validHeaderValueChar(ch)) return false;
    }
    return true;
}

fn validHeaderKeyChar(ch: u8) bool {
    return !std.ascii.isControl(ch) and ch != ':' and
        !std.ascii.isWhitespace(ch) and ch != '@';
}

fn validHeaderValueChar(ch: u8) bool {
    if (std.ascii.isControl(ch)) {
        if (ch != '\t') return false;
    }
    return true;
}

pub fn parseResponse(
    arena: Allocator,
    res: []const u8,
) ParseError!*http.Response {
    if (!std.mem.containsAtLeast(u8, res, 2, "\r\n")) {
        return error.InvalidHttpMessage;
    }
    var lines = std.mem.splitSequence(u8, res, "\r\n");
    const status_line = try parseStatusLine(lines.next().?);

    var headers = std.StringHashMap([]const u8).init(arena);

    while (lines.next()) |header| {
        // \r\n\r\n pattern found
        if (header.len == 0) break;
        const kv = try parseHeader(arena, header);
        try headers.put(kv.key, kv.value);
    }

    const body =
        if (lines.next()) |b| try arena.dupe(u8, b) else "";

    const response = try arena.create(http.Response);
    response.* = http.Response{
        .status_code = status_line.status_code,
        .protocol = status_line.protocol,
        .headers = headers,
        .body = body,
        .arena = arena,
    };
    return response;
}

fn parseStatusLine(
    status_line: []const u8,
) ParseError!struct {
    protocol: http.Protocol,
    status_code: http.Status,
} {
    if (!std.mem.containsAtLeast(u8, status_line, 2, " ")) {
        return error.InvalidStatusLine;
    }
    var els = std.mem.splitScalar(u8, status_line, ' ');
    const protocol = http.Protocol.from(els.next().?) orelse
        return error.InvalidProtocol;

    const status_number = try std.fmt.parseInt(u10, els.next().?, 10);
    const status_code = std.meta.intToEnum(
        http.Status,
        status_number,
    ) catch unreachable;

    return .{
        .protocol = protocol,
        .status_code = status_code,
    };
}

test parseRequest {
    const Test = struct {
        expected: struct {
            method: http.Method,
            protocol: http.Protocol,
            url_path: []const u8,
            headers: std.StaticStringMap([]const u8),
            body: []const u8,
        },
        request_str: []const u8,
    };

    const tests = [_]Test{
        .{
            .request_str = "GET /static/image.png HTTP/1.1\r\n" ++
                "Host: www.example.com\r\n" ++
                "User-Agent: Mozilla/5.0\r\n" ++
                "Accept: text/html\r\n" ++
                "Connection: close\r\n\r\n",
            .expected = .{
                .method = .get,
                .protocol = .http11,
                .url_path = "/static/image.png",
                .headers = .initComptime(&.{
                    .{ "Host", "www.example.com" },
                    .{ "User-Agent", "Mozilla/5.0" },
                    .{ "Accept", "text/html" },
                    .{ "Connection", "close" },
                }),
                .body = "",
            },
        },
        .{
            .request_str = "GET /static/image.png HTTP/1.1\r\n" ++
                "Host: www.example.com\r\n" ++
                "User-Agent: Mozilla/5.0\r\n" ++
                "Accept: text/html\r\n" ++
                "Connection: close\r\n\r\n",
            .expected = .{
                .method = .get,
                .protocol = .http11,
                .url_path = "/static/image.png",
                .headers = .initComptime(&.{
                    .{ "Host", "www.example.com" },
                    .{ "User-Agent", "Mozilla/5.0" },
                    .{ "Accept", "text/html" },
                    .{ "Connection", "close" },
                }),
                .body = "",
            },
        },
        .{
            .request_str = "POST /login HTTP/1.1\r\n" ++
                "Host: auth.example.com\r\n" ++
                "User-Agent: ZigTester/1.0\r\n" ++
                "Content-Type: application/x-www-form-urlencoded\r\n" ++
                "Content-Length: 29\r\n" ++
                "Connection: keep-alive\r\n\r\n" ++
                "username=alice&password=1234",
            .expected = .{
                .method = .post,
                .protocol = .http11,
                .url_path = "/login",
                .headers = .initComptime(&.{
                    .{ "Host", "auth.example.com" },
                    .{ "User-Agent", "ZigTester/1.0" },
                    .{ "Content-Type", "application/x-www-form-urlencoded" },
                    .{ "Content-Length", "29" },
                    .{ "Connection", "keep-alive" },
                }),
                .body = "username=alice&password=1234",
            },
        },
        .{
            .request_str = "PUT /api/user/42 HTTP/1.1\r\n" ++
                "Host: api.example.com\r\n" ++
                "Content-Type: application/json\r\n" ++
                "Content-Length: 25\r\n\r\n" ++
                "{\"name\":\"Bob\",\"age\":30}",
            .expected = .{
                .method = .put,
                .protocol = .http11,
                .url_path = "/api/user/42",
                .headers = .initComptime(&.{
                    .{ "Host", "api.example.com" },
                    .{ "Content-Type", "application/json" },
                    .{ "Content-Length", "25" },
                }),
                .body = "{\"name\":\"Bob\",\"age\":30}",
            },
        },
        .{
            .request_str = "DELETE /posts/99 HTTP/1.1\r\n" ++
                "Host: blog.example.com\r\n" ++
                "Authorization: Bearer xyz123\r\n" ++
                "User-Agent: ZigClient/2.0\r\n\r\n",
            .expected = .{
                .method = .delete,
                .protocol = .http11,
                .url_path = "/posts/99",
                .headers = .initComptime(&.{
                    .{ "Host", "blog.example.com" },
                    .{ "Authorization", "Bearer xyz123" },
                    .{ "User-Agent", "ZigClient/2.0" },
                }),
                .body = "",
            },
        },
        .{
            .request_str = "PATCH /account/settings HTTP/1.1\r\n" ++
                "Host: user.example.org\r\n" ++
                "Content-Type: application/json\r\n" ++
                "X-Custom-Flag: true\r\n" ++
                "Content-Length: 22\r\n\r\n" ++
                "{\"theme\":\"darkmode\"}",
            .expected = .{
                .method = .patch,
                .protocol = .http11,
                .url_path = "/account/settings",
                .headers = .initComptime(&.{
                    .{ "Host", "user.example.org" },
                    .{ "Content-Type", "application/json" },
                    .{ "X-Custom-Flag", "true" },
                    .{ "Content-Length", "22" },
                }),
                .body = "{\"theme\":\"darkmode\"}",
            },
        },
        .{
            .request_str = "HEAD /ping HTTP/1.1\r\n" ++
                "Host: healthcheck.example.net\r\n" ++
                "User-Agent: MonitorBot/1.0\r\n" ++
                "Connection: close\r\n\r\n",
            .expected = .{
                .method = .head,
                .protocol = .http11,
                .url_path = "/ping",
                .headers = .initComptime(&.{
                    .{ "Host", "healthcheck.example.net" },
                    .{ "User-Agent", "MonitorBot/1.0" },
                    .{ "Connection", "close" },
                }),
                .body = "",
            },
        },
        .{
            .request_str = "GET http://www.example.com/static/image.png HTTP/1.1\r\n" ++
                "Host: www.example.com\r\n" ++
                "User-Agent: Mozilla/5.0\r\n" ++
                "Accept: text/html\r\n" ++
                "Connection: close\r\n\r\n",
            .expected = .{
                .method = .get,
                .protocol = .http11,
                .url_path = "/static/image.png",
                .headers = .initComptime(&.{
                    .{ "Host", "www.example.com" },
                    .{ "User-Agent", "Mozilla/5.0" },
                    .{ "Accept", "text/html" },
                    .{ "Connection", "close" },
                }),
                .body = "",
            },
        },
        .{
            .request_str = "POST /login HTTP/1.1\r\n" ++
                "Host: auth.example.com\r\n" ++
                "User-Agent: ZigTester/1.0\r\n" ++
                "Content-Type: application/x-www-form-urlencoded\r\n" ++
                "Content-Length: 29\r\n" ++
                "Connection: keep-alive\r\n\r\n" ++
                "username=alice&password=1234",
            .expected = .{
                .method = .post,
                .protocol = .http11,
                .url_path = "/login",
                .headers = .initComptime(&.{
                    .{ "Host", "auth.example.com" },
                    .{ "User-Agent", "ZigTester/1.0" },
                    .{ "Content-Type", "application/x-www-form-urlencoded" },
                    .{ "Content-Length", "29" },
                    .{ "Connection", "keep-alive" },
                }),
                .body = "username=alice&password=1234",
            },
        },
    };

    const host = "127.0.0.1";
    var server = try http.Server.init(std.testing.allocator, host, 8080);
    defer server.event_loop.deinit();

    var arena = std.heap.ArenaAllocator.init(server.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    for (&tests, 0..) |*t, i| {
        const req = try parseRequest(&server, t.request_str, alloc);
        errdefer std.debug.print(
            "Test #{} failed. Request string is\n{s}\nParsed request is\n{}",
            .{ i, t.request_str, req },
        );

        try std.testing.expect(req.method == t.expected.method);
        try std.testing.expect(req.protocol == t.expected.protocol);
        try std.testing.expectEqualStrings(req.url.path.str, t.expected.url_path);

        const headers = &req.headers;
        try std.testing.expect(t.expected.headers.keys().len == headers.count());

        for (0..t.expected.headers.keys().len) |j| {
            const expected_key = t.expected.headers.keys()[j];
            const expected_value = t.expected.headers.values()[j];

            const actual = headers.get(expected_key) orelse {
                std.debug.print("Key {s} not found in headers\n", .{expected_key});
                return error.TestFailed;
            };
            try std.testing.expectEqualStrings(actual, expected_value);
        }
        try std.testing.expectEqualStrings(req.body, t.expected.body);
    }
}

// TODO: write tests for body parsing and just add more full
// response and request parsing tests in general
test parseResponse {
    const Test = struct {
        expected: struct {
            status_code: http.Status,
            protocol: http.Protocol,
            headers: std.StaticStringMap([]const u8),
            body: []const u8,
        },
        response_str: []const u8,
    };

    var tests = [_]Test{
        .{
            .response_str = "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: image/png\r\n" ++
                "Content-Length: 12345\r\n" ++
                "Connection: close\r\n" ++
                "Server: example-server\r\n\r\n",
            .expected = .{
                .status_code = .ok,
                .protocol = .http11,
                .headers = .initComptime(&.{
                    .{ "Content-Type", "image/png" },
                    .{ "Content-Length", "12345" },
                    .{ "Connection", "close" },
                    .{ "Server", "example-server" },
                }),
                .body = "",
            },
        },
        .{
            .response_str = "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: image/png\r\n" ++
                "Content-Length: 12345\r\n" ++
                "Connection: close\r\n" ++
                "Server: example-server\r\n\r\n",
            .expected = .{
                .status_code = .ok,
                .protocol = .http11,
                .headers = .initComptime(&.{
                    .{ "Content-Type", "image/png" },
                    .{ "Content-Length", "12345" },
                    .{ "Connection", "close" },
                    .{ "Server", "example-server" },
                }),
                .body = "",
            },
        },
        .{
            .response_str = "HTTP/1.1 404 Not Found\r\n" ++
                "Content-Type: text/html\r\n" ++
                "Content-Length: 22\r\n" ++
                "Connection: close\r\n\r\n" ++
                "<h1>Not Found</h1>",
            .expected = .{
                .status_code = .not_found,
                .protocol = .http11,
                .headers = .initComptime(&.{
                    .{ "Content-Type", "text/html" },
                    .{ "Content-Length", "22" },
                    .{ "Connection", "close" },
                }),
                .body = "<h1>Not Found</h1>",
            },
        },
        .{
            .response_str = "HTTP/1.1 500 Internal Server Error\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: 17\r\n" ++
                "Connection: close\r\n\r\n" ++
                "Server failure.\n",
            .expected = .{
                .status_code = .internal_server_error,
                .protocol = .http11,
                .headers = .initComptime(&.{
                    .{ "Content-Type", "text/plain" },
                    .{ "Content-Length", "17" },
                    .{ "Connection", "close" },
                }),
                .body = "Server failure.\n",
            },
        },
        .{
            .response_str = "HTTP/1.1 201 Created\r\n" ++
                "Content-Type: application/json\r\n" ++
                "Content-Length: 27\r\n" ++
                "Location: /api/item/42\r\n\r\n" ++
                "{\"id\":42,\"status\":\"ok\"}",
            .expected = .{
                .status_code = .created,
                .protocol = .http11,
                .headers = .initComptime(&.{
                    .{ "Content-Type", "application/json" },
                    .{ "Content-Length", "27" },
                    .{ "Location", "/api/item/42" },
                }),
                .body = "{\"id\":42,\"status\":\"ok\"}",
            },
        },
        .{
            .response_str = "HTTP/1.1 204 No Content\r\n" ++
                "Content-Length: 0\r\n" ++
                "Connection: keep-alive\r\n\r\n",
            .expected = .{
                .status_code = .no_content,
                .protocol = .http11,
                .headers = .initComptime(&.{
                    .{ "Content-Length", "0" },
                    .{ "Connection", "keep-alive" },
                }),
                .body = "",
            },
        },
        .{
            .response_str = "HTTP/1.1 301 Moved Permanently\r\n" ++
                "Location: https://new.example.com/\r\n" ++
                "Content-Length: 0\r\n" ++
                "Connection: close\r\n\r\n",
            .expected = .{
                .status_code = .moved_permanently,
                .protocol = .http11,
                .headers = .initComptime(&.{
                    .{ "Location", "https://new.example.com/" },
                    .{ "Content-Length", "0" },
                    .{ "Connection", "close" },
                }),
                .body = "",
            },
        },
        .{
            .response_str = "HTTP/1.1 403 Forbidden\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: 13\r\n\r\n" ++
                "Access denied",
            .expected = .{
                .status_code = .forbidden,
                .protocol = .http11,
                .headers = .initComptime(&.{
                    .{ "Content-Type", "text/plain" },
                    .{ "Content-Length", "13" },
                }),
                .body = "Access denied",
            },
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for (&tests, 0..) |*t, i| {
        errdefer std.debug.print(
            "Test #{} failed. Response string is\n{s}\n",
            .{ i, t.response_str },
        );

        const res = try parseResponse(alloc, t.response_str);

        try std.testing.expect(res.status_code == t.expected.status_code);
        try std.testing.expect(res.protocol == t.expected.protocol);

        const headers = &res.headers;
        try std.testing.expect(t.expected.headers.keys().len == headers.count());

        for (0..t.expected.headers.keys().len) |j| {
            const expected_key = t.expected.headers.keys()[j];
            const expected_value = t.expected.headers.values()[j];

            const actual = headers.get(expected_key) orelse {
                std.debug.print("Key {s} not found in headers\n", .{expected_key});
                return error.TestFailed;
            };
            try std.testing.expectEqualStrings(actual, expected_value);
        }
        try std.testing.expectEqualStrings(res.body, t.expected.body);
    }
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

test parseStatusLine {
    const Test = struct {
        status_line: []const u8,
        expected: @typeInfo(@TypeOf(parseStatusLine)).@"fn".return_type.?,
    };
    var tests = [_]Test{
        .{
            .status_line = "HTTP/1.1 404 Not Found",
            .expected = .{ .protocol = .http11, .status_code = .not_found },
        },
        .{
            .status_line = "HTTP/2.5 200 OK",
            .expected = error.InvalidProtocol,
        },
        .{
            .status_line = "HTTP/1.1 404Not Found",
            .expected = error.InvalidCharacter,
        },
        .{
            .status_line = "HTTP/1.1 9000 Oops",
            .expected = error.Overflow,
        },
        .{
            .status_line = "HTTP/1.1 418 I'm a teapot",
            .expected = .{ .protocol = .http11, .status_code = .teapot },
        },
    };
    for (&tests, 0..) |*t, i| {
        errdefer std.debug.print("Test #{} [{s}]\n", .{ i, t.status_line });
        const sl = parseStatusLine(t.status_line);
        try std.testing.expectEqual(sl, t.expected);
    }
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

test isValidHeader {
    const Test = struct {
        header: []const u8,
        expected: bool,
    };
    const tests = [_]Test{
        .{
            .header = "Host: example.com",
            .expected = true,
        },
        .{
            .header = "User-Agent: curl/7.68.0",
            .expected = true,
        },
        .{
            .header = "X-Custom-Header_123: abcDEF-456_xyz",
            .expected = true,
        },
        .{
            .header = "Accept-Encoding: gzip, deflate",
            .expected = true,
        },
        .{
            .header = "X-Token: !#$%&'*+-.^_`|~",
            .expected = true,
        },
        .{
            .header = "Authorization: Bearer abc.def.ghi",
            .expected = true,
        },
        .{
            .header = "Invalid Header: value", // space in key
            .expected = false,
        },
        .{
            .header = "User@Agent: curl", // invalid char '@'
            .expected = false,
        },
        .{
            .header = "Content-Type: text/html\ntext/plain", // newline in value
            .expected = false,
        },
        .{
            .header = ": no-key", // empty key
            .expected = false,
        },
        .{
            .header = " X-Key: value", // space before key
            .expected = false,
        },
        .{
            .header = "Key : value", // space before colon
            .expected = false,
        },
        .{
            .header = "Key: value\x00withnull", // null byte
            .expected = false,
        },
        .{
            .header = "Key: value\x1F", // control character
            .expected = false,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for (&tests) |*t| {
        const header = http.parser.parseHeader(alloc, t.header) catch |err| {
            std.debug.print("parse header failed\n", .{});
            return err;
        };
        errdefer std.debug.print(
            "[{s}] got={} expected={}\n",
            .{ t.header, isValidHeader(header.key, header.value), t.expected },
        );
        try std.testing.expect(
            isValidHeader(header.key, header.value) == t.expected,
        );
    }
}

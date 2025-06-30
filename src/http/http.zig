const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
pub const Status = std.http.Status;

pub const Client = @import("Client.zig");
pub const parser = @import("parser.zig");
pub const Request = @import("Request.zig");
pub const Response = @import("Response.zig");
pub const Router = @import("Router.zig");
pub const Server = @import("Server.zig");
pub const Handler = @import("Handler.zig");
pub const Mime = @import("mime.zig").Mime;

const log = std.log.scoped(.http);

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

/// small wrapper around a path for convenience
pub const Path = struct {
    path: []const u8,

    pub fn eql(self: Path, other: []const u8) bool {
        return std.mem.eql(u8, self.path, other);
    }

    pub fn exists(self: Path) bool {
        std.fs.cwd().access(self.path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound,
                error.NameTooLong,
                error.BadPathName,
                error.InvalidUtf8,
                error.InvalidWtf8,
                => return false,
                else => return true,
            }
        };
        return true;
    }

    pub fn kind(self: Path) std.fs.Dir.StatFileError!std.fs.File.Kind {
        const stat = std.fs.cwd().statFile(self.path) catch unreachable;
        return stat.kind;
    }
};

pub const UrlParseError = std.fmt.BufPrintError || Allocator.Error;

pub const Url = struct {
    /// this must always be an absolute url
    raw: []const u8,

    /// hst must not contain an ending /
    /// relative must start with a /
    pub fn fromRelative(
        alloc: Allocator,
        relative: []const u8,
        protocol: Protocol,
        hst: []const u8,
        prt: ?u16,
    ) UrlParseError!Url {
        // TODO: support queries in fromRelative
        const scheme = switch (protocol) {
            .http11 => "http",
        };

        // u16 can have at most 5 digits
        const port_str: ?[]const u8 = str: {
            if (prt) |p| {
                var buf: [5]u8 = undefined;
                break :str try std.fmt.bufPrint(&buf, "{}", .{p});
            }
            break :str null;
        };
        const raw = try std.mem.concat(alloc, u8, &.{
            scheme,
            "://",
            hst,
            if (prt != null) ":" else "",
            port_str orelse "",
            relative,
        });
        return .init(raw);
    }

    pub fn init(raw: []const u8) Url {
        // TODO: create a hashmap of queries
        return .{ .raw = raw };
    }

    pub fn host(self: Url) []const u8 {
        // remove scheme
        var it = std.mem.splitSequence(u8, self.raw, "://");
        _ = it.next().?;
        const s1 = it.next().?;

        // port exists
        if (std.mem.indexOf(u8, s1, ":")) |i| {
            return s1[0..i];
        }
        return s1[0..std.mem.indexOf(u8, s1, "/").?];
    }

    pub fn port(self: Url) std.fmt.ParseIntError!?u16 {
        // remove scheme
        var it = std.mem.splitSequence(u8, self.raw, "://");
        _ = it.next().?;
        const s1 = it.next().?;

        // port exists
        if (std.mem.indexOf(u8, s1, ":")) |i| {
            const end = std.mem.indexOf(u8, s1, "/").?;
            return try std.fmt.parseInt(u16, s1[i + 1 .. end], 10);
        }
        return null;
    }

    pub fn path(self: Url) Path {
        // remove scheme
        var it = std.mem.splitSequence(u8, self.raw, "://");
        _ = it.next().?;
        const s1 = it.next().?;

        const i = std.mem.indexOf(u8, s1, "/").?;
        if (std.mem.indexOf(u8, s1, "?")) |end| {
            return Path{ .path = s1[i..end] };
        }
        return Path{ .path = s1[i..] };
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
        _ = buf; // autofix
        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return alloc.dupe(u8, msg);
            }
            try self.readSocket();
        }
    }

    fn readSocket(self: *HttpReader) !void {
        const pos = self.pos;

        const n = try posix.read(self.socket, self.buf.items[pos..]);
        if (n == 0) {
            if (self.pos == self.buf.items.len) {
                try self.ensureSpace(self.buf.capacity * 2);
                return;
            }
            return error.Closed;
        }
        self.pos = pos + n;
    }

    /// if null, there is no body
    fn bodyLen(msg: []const u8) std.fmt.ParseIntError!?usize {
        const header = "Content-Length: ";
        const index = std.mem.indexOf(u8, msg, header);
        if (index) |i| {
            const start = i + header.len;
            const end = std.mem.indexOf(u8, msg[start..], "\r\n").? + start;
            return try std.fmt.parseInt(usize, msg[start..end], 10);
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
            return try self.extractBody(start);
        }
        return null;
    }

    fn extractBody(self: *HttpReader, start: usize) ![]u8 {
        const msg = self.buf.items[start..self.start];
        const body_len = try bodyLen(msg) orelse return msg;
        if (body_len == 0) return msg;

        while (true) {
            if (self.pos - self.start >= body_len) {
                self.start += body_len;
                return self.buf.items[start..self.start];
            }
            try self.readSocket();
        }
        return msg;
    }
};

/// only sets the response's body, nothing else
/// the caller must set the content type and status code
pub fn serveFile(res: *Response, path: []const u8) !void {
    const f = try std.fs.cwd().readFileAlloc(
        res.arena,
        path,
        std.math.maxInt(u32),
    );
    res.body = f;
}

pub fn notFound(res: *Response, path: []const u8) !void {
    res.status_code = .not_found;
    try res.headers.put("Content-Type", "text/html");
    res.body = try std.fmt.allocPrint(
        res.arena,
        "<h1>404 - Not Found</h1><p>{s} is not a valid url</p>\n",
        .{path},
    );
}

fn fileExtension(f: []const u8) ?[]const u8 {
    var iter = std.mem.splitBackwardsScalar(u8, f, '.');
    return iter.next();
}

pub const StripPrefix = struct {
    underlying: Handler,
    prefix: []const u8,

    pub fn handle(ctx: ?*anyopaque, res: *Response, req: *const Request) !void {
        const self: *StripPrefix = @ptrCast(@alignCast(ctx.?));
        const path = req.url.path().path;
        const index = std.mem.indexOf(u8, path, self.prefix);
        if (index) |i| {
            const new_path = path[i + self.prefix.len - 1 ..];
            var new_req = req.*;
            new_req.url = try Url.fromRelative(
                res.arena,
                new_path,
                .http11,
                req.url.host(),
                try req.url.port(),
            );
            try self.underlying.handle(res, &new_req);
            // if not found, then send a better error message with the proper path
            // and not the stripped one
            if (res.status_code != .not_found) return;
        }
        return notFound(res, path);
    }

    pub fn handler(self: *StripPrefix) Handler {
        return .{
            .ptr = self,
            .vtable = &.{
                .handle = handle,
            },
        };
    }
};

pub const FileServer = struct {
    dir: std.fs.Dir,

    pub fn init(
        dir_path: []const u8,
    ) std.fs.Dir.OpenError!FileServer {
        const dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        return .{
            .dir = dir,
        };
    }

    fn deinit(ctx: ?*anyopaque) void {
        const self: *FileServer = @ptrCast(@alignCast(ctx.?));
        self.dir.close();
    }

    pub fn handle(ctx: ?*anyopaque, res: *Response, req: *const Request) !void {
        const self: *FileServer = @ptrCast(@alignCast(ctx.?));
        const path = Path{
            .path = req.url.path().path[1..], // remove the beginning /
        };
        var iter = self.dir.iterate();
        while (try iter.next()) |file| {
            if (file.kind == .file and path.eql(file.name)) {
                res.status_code = .ok;
                const ext = fileExtension(file.name).?;
                const content_type: []const u8 = ty: {
                    if (Mime.from(ext)) |mime| {
                        break :ty mime.str();
                    }
                    break :ty "application/octect-stream";
                };
                try res.headers.put("Content-Type", content_type);
                const f = try self.dir.readFileAlloc(
                    res.arena,
                    path.path,
                    std.math.maxInt(u32),
                );
                res.body = f;
                return;
            }
        }
        return notFound(res, path.path);
    }

    pub fn handler(self: *FileServer) Handler {
        return .{
            .ptr = self,
            .vtable = &.{
                .handle = handle,
                .deinit = deinit,
            },
        };
    }
};

test "HttpReader.bufferedMessage multiple messages" {
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

test "HttpReader.bufferedMessage no body" {
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

test "HttpReader.bufferedMessage garbage bytes" {
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

test "HttpReader.bodyLen" {
    const msg =
        "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Type: text/html\r\nContent-Length: 64\r\n\r\n<html><body><h1>Hello, world!</h1><p>This is a test.</p></body></html>";
    const len = try HttpReader.bodyLen(msg);
    try std.testing.expect(len.? == 64);
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

test Url {
    const Test = struct {
        raw: []const u8,
        host: []const u8,
        port: ?u16,
        path: []const u8,
    };

    const tests = [_]Test{
        .{
            .raw = "http://example.com/search",
            .host = "example.com",
            .port = null,
            .path = "/search",
        },
        .{
            .raw = "http://example.com/search?q=books",
            .host = "example.com",
            .port = null,
            .path = "/search",
        },
        .{
            .raw = "http://example.com:8080/search",
            .host = "example.com",
            .port = 8080,
            .path = "/search",
        },
        .{
            .raw = "http://example.com:8080/search?q=books",
            .host = "example.com",
            .port = 8080,
            .path = "/search",
        },
        .{
            .raw = "http://example.com/api/user",
            .host = "example.com",
            .port = null,
            .path = "/api/user",
        },
        .{
            .raw = "http://example.com/api/user?id=5",
            .host = "example.com",
            .port = null,
            .path = "/api/user",
        },
        .{
            .raw = "http://example.com:3000/api/user",
            .host = "example.com",
            .port = 3000,
            .path = "/api/user",
        },
        .{
            .raw = "http://example.com:3000/api/user?id=5",
            .host = "example.com",
            .port = 3000,
            .path = "/api/user",
        },
    };
    for (&tests, 0..) |*t, i| {
        const url = Url{ .raw = t.raw };
        errdefer {
            std.debug.print("Failed test {}\n", .{i});
            std.debug.print("[path] got={s} expected={s}\n", .{ url.path().path, t.path });
            std.debug.print("[host] got={s} expected={s}\n", .{ url.host(), t.host });
            std.debug.print("[port] got={!?} expected={?}\n", .{ url.port(), t.port });
        }

        try std.testing.expect(url.path().eql(t.path));
        try std.testing.expect(std.mem.eql(u8, url.host(), t.host));
        try std.testing.expect(try url.port() == t.port);
    }
}

test "Url.fromRelative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    const Test = struct {
        expected: []const u8,
        relative: []const u8,
        host: []const u8,
        protocol: Protocol = .http11,
        port: ?u16,
    };
    const tests = [_]Test{
        .{
            .expected = "http://example.com/search",
            .host = "example.com",
            .port = null,
            .relative = "/search",
        },
        .{
            .expected = "http://example.com/search",
            .host = "example.com",
            .port = null,
            .relative = "/search",
        },
        .{
            .expected = "http://example.com:8080/search",
            .host = "example.com",
            .port = 8080,
            .relative = "/search",
        },
        .{
            .expected = "http://example.com:8080/search",
            .host = "example.com",
            .port = 8080,
            .relative = "/search",
        },
        .{
            .expected = "http://example.com/api/user",
            .host = "example.com",
            .port = null,
            .relative = "/api/user",
        },
        .{
            .expected = "http://example.com/api/user",
            .host = "example.com",
            .port = null,
            .relative = "/api/user",
        },
        .{
            .expected = "http://example.com:3000/api/user",
            .host = "example.com",
            .port = 3000,
            .relative = "/api/user",
        },
        .{
            .expected = "http://example.com:3000/api/user",
            .host = "example.com",
            .port = 3000,
            .relative = "/api/user",
        },
    };
    for (&tests) |*t| {
        const url = try Url.fromRelative(alloc, t.relative, t.protocol, t.host, t.port);
        try std.testing.expect(std.mem.eql(u8, url.raw, t.expected));
    }
}

test fileExtension {
    const Test = struct {
        file: []const u8,
        expected: []const u8,
    };
    const tests = [_]Test{
        .{
            .file = "index.html",
            .expected = "html",
        },
        .{
            .file = "image.test.png",
            .expected = "png",
        },
    };
    for (&tests) |t| {
        try std.testing.expect(
            std.mem.eql(u8, fileExtension(t.file).?, t.expected),
        );
    }
}

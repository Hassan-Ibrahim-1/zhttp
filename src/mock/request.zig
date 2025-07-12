const std = @import("std");
const posix = std.posix;

const http = @import("../http/http.zig");
const log = std.log.scoped(.request);

/// url must be formatted like so http://hostname/path/more
pub fn get(
    arena: std.mem.Allocator,
    url: []const u8,
    port: ?u16,
) !*http.Response {
    const req = http.Request{
        .method = .get,
        .protocol = .http11,
        .url = .init(url),
        .headers = .init(arena),
        .body = "",
        .arena = undefined,
    };

    const addr_list = try std.net.getAddressList(
        arena,
        req.url.host,
        port orelse http.default_port,
    );
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) return error.AddressNotFound;

    const stream = st: {
        for (addr_list.addrs) |addr| {
            break :st std.net.tcpConnectToAddress(addr) catch continue;
        }
        return error.NoValidAddress;
    };
    defer stream.close();

    const req_str = try std.fmt.allocPrint(arena, "{}", .{req});
    defer arena.free(req_str);

    var writer = http.HttpWriter{
        .buf = req_str,
        .socket = stream.handle,
    };
    try writer.write();

    var reader = http.HttpReader.init(arena, stream.handle);
    defer reader.deinit();

    const res_str = try reader.readMessage(arena);
    defer arena.free(res_str);

    return http.parser.parseResponse(arena, res_str);
}

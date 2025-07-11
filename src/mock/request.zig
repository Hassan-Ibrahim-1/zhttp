const std = @import("std");
const posix = std.posix;

const http = @import("../http/http.zig");
const log = std.log.scoped(.request);

pub fn request(
    arena: std.mem.Allocator,
    host: []const u8,
    port: ?u16,
) !*http.Response {
    const req = http.Request{
        .method = .get,
        .protocol = .http11,
        .url = try .fromRelative(arena, "/", .http11, host, null),
        .headers = .init(arena),
        .body = "",
        .arena = undefined,
    };

    const addr_list = try std.net.getAddressList(
        arena,
        host,
        port orelse http.default_port,
    );
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) return error.AddressNotFound;

    for (addr_list.addrs) |a| {
        log.info("addr: {}", .{a});
    }

    const addr = addr_list.addrs[0];

    const tpe: u32 = posix.SOCK.STREAM;
    const protocol: u32 = posix.IPPROTO.TCP;
    const client = try posix.socket(addr.any.family, tpe, protocol);

    try posix.setsockopt(
        client,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    const stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    const req_str = try std.fmt.allocPrint(arena, "{}", .{req});
    defer arena.free(req_str);

    var writer = http.HttpWriter{ .buf = req_str, .socket = stream.handle };
    try writer.write();

    var reader = http.HttpReader.init(arena, stream.handle);
    defer reader.deinit();

    // const res_str = try stream.reader()
    //     .readAllAlloc(arena, std.math.maxInt(usize));

    const res_str = try reader.readMessage(arena);
    defer arena.free(res_str);

    return http.parser.parseResponse(arena, res_str);
}

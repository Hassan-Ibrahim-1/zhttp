const std = @import("std");
const posix = std.posix;

const http = @import("root").http;

pub fn request(
    alloc: std.mem.Allocator,
    addr: std.net.Address,
    req: *const http.Request,
) http.Response {
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

    const req_str = try std.fmt.allocPrint(alloc, "{}", .{req});
    defer alloc.free(req_str);

    var writer = http.HttpWriter{ .buf = req_str, .socket = stream.handle };
    try writer.write();

    var reader = http.HttpReader.init(alloc, stream.handle);
    defer reader.deinit();

    const res_str = reader.readMessage(alloc);
    _ = res_str; // autofix
}

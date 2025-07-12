const std = @import("std");
const posix = std.posix;

const http = @import("http.zig");

pub fn request(addr: std.net.Address, req: http.Request) http.Response {
    _ = addr; // autofix
    _ = req; // autofix
}

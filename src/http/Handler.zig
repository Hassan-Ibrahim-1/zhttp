const std = @import("std");

const http = @import("http.zig");
const Request = http.Request;
const Response = http.Response;

const Handler = @This();

pub const HandleFn = *const fn (
    ctx: ?*anyopaque,
    res: *Response,
    req: *const Request,
) anyerror!void;

ptr: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    handle: HandleFn,
};

pub fn from(comptime func: HandleFn) Handler {
    return .{
        .ptr = null,
        .vtable = &.{
            .handle = func,
        },
    };
}

pub fn handle(
    self: Handler,
    res: *Response,
    req: *const Request,
) !void {
    return self.vtable.handle(self.ptr, res, req);
}

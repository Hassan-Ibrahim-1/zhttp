const std = @import("std");

pub const log = @import("log.zig");

pub const Mode = enum {
    append,
    write,
};

pub fn dump(file_name: []const u8, msg: []const u8, mode: Mode) void {
    const file = switch (mode) {
        .append => std.fs.cwd().openFile(file_name, .{ .mode = .write_only }) catch unreachable,
        .write => std.fs.cwd().createFile(file_name, .{}) catch unreachable,
    };
    defer file.close();
    file.writeAll(msg) catch unreachable;
}

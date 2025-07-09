const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const builtin = @import("builtin");

const http = @import("../http.zig");

pub const EventLoop = struct {
    impl: Impl,

    pub fn init() !EventLoop {
        return .{
            .impl = try Impl.init(),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.impl.deinit();
    }

    pub fn wait(self: *EventLoop) Impl.Iterator {
        return self.impl.wait();
    }

    pub fn addListener(self: *EventLoop, listener: posix.socket_t) !void {
        try self.impl.addListener(listener);
    }

    pub fn removeListener(self: *EventLoop, listener: posix.socket_t) !void {
        try self.impl.removeListener(listener);
    }

    pub fn newClient(self: *EventLoop, client: *http.Client) !void {
        try self.impl.newClient(client);
    }

    pub fn setIoMode(self: *EventLoop, client: *http.Client, mode: Mode) !void {
        try self.impl.setIoMode(client, mode);
    }
};

pub const Mode = enum {
    read,
    write,
};

const Impl = if (builtin.os.tag == .linux) Epoll else @compileError("unsupported platform");

pub const Event = union(enum) {
    accept: void,
    read: *http.Client,
    write: *http.Client,
};

const Epoll = struct {
    efd: posix.fd_t,
    ready_list: [128]linux.epoll_event = undefined,

    pub const Iterator = struct {
        index: usize,
        ready_list: []linux.epoll_event,

        pub fn next(self: *Iterator) ?Event {
            if (self.index == self.ready_list.len) return null;
            defer self.index += 1;

            const ready = self.ready_list[self.index];
            return switch (ready.data.ptr) {
                0 => .accept,
                else => |nptr| ret: {
                    const client: *http.Client = @ptrFromInt(nptr);
                    if (ready.events & linux.POLL.IN == linux.POLL.IN) {
                        break :ret .{ .read = client };
                    }
                    break :ret .{ .write = client };
                },
            };
        }
    };

    fn init() posix.EpollCreateError!Epoll {
        const efd = try posix.epoll_create1(0);
        return Epoll{
            .efd = efd,
        };
    }

    fn deinit(self: *Epoll) void {
        posix.close(self.efd);
    }

    fn wait(self: *Epoll) Iterator {
        const count = posix.epoll_wait(self.efd, &self.ready_list, -1);
        const rl = self.ready_list[0..count];
        return .{
            .index = 0,
            .ready_list = rl,
        };
    }

    fn addListener(self: *Epoll, listener: posix.socket_t) !void {
        var event = linux.epoll_event{
            .events = linux.POLL.IN,
            .data = .{ .ptr = 0 },
        };
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_ADD, listener, &event);
    }

    fn removeListener(self: *Epoll, listener: posix.socket_t) !void {
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_DEL, listener, null);
    }

    fn newClient(self: *Epoll, client: *http.Client) !void {
        var event = linux.epoll_event{
            .events = linux.POLL.IN,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try posix.epoll_ctl(
            self.efd,
            linux.EPOLL.CTL_ADD,
            client.socket,
            &event,
        );
    }

    fn setIoMode(self: *Epoll, client: *http.Client, mode: Mode) !void {
        var event = linux.epoll_event{
            .events = switch (mode) {
                .read => linux.POLL.IN,
                .write => linux.POLL.OUT,
            },
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try posix.epoll_ctl(
            self.efd,
            linux.EPOLL.CTL_MOD,
            client.socket,
            &event,
        );
    }
};

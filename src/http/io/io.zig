const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const builtin = @import("builtin");

const http = @import("../http.zig");
pub const Scheduler = @import("Scheduler.zig");

const ready_list_len = 1024;

pub const EventLoop = struct {
    mu: std.Thread.Mutex,
    impl: Impl,

    pub fn init() !EventLoop {
        return .{
            .impl = try Impl.init(),
            .mu = .{},
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.impl.deinit();
    }

    pub fn wait(self: *EventLoop) !Impl.Iterator {
        return try self.impl.wait();
    }

    pub fn addListener(self: *EventLoop, listener: posix.socket_t) !void {
        try self.impl.addListener(listener);
    }

    pub fn removeListener(self: *EventLoop, listener: posix.socket_t) !void {
        try self.impl.removeListener(listener);
    }

    pub fn newConnectionNode(self: *EventLoop, node: *http.ConnectionNode) !void {
        try self.impl.newConnectionNode(node);
    }

    pub fn setIoMode(self: *EventLoop, node: *http.ConnectionNode, mode: Mode) !void {
        self.mu.lock();
        defer self.mu.unlock();

        try self.impl.setIoMode(node, mode);
    }
};

pub const Mode = enum {
    read,
    write,
};

const Impl = switch (builtin.os.tag) {
    .linux => Epoll,
    .freebsd, .macos => KQueue,
    else => @compileError("unsupported os"),
};

pub const Event = union(enum) {
    accept: void,
    read: *http.ConnectionNode,
    write: *http.ConnectionNode,
};

const Epoll = struct {
    efd: posix.fd_t,
    ready_list: [ready_list_len]linux.epoll_event = undefined,

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
                    const client: *http.ConnectionNode = @ptrFromInt(nptr);
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

    fn wait(self: *Epoll) !Iterator {
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

    fn newConnectionNode(self: *Epoll, node: *http.ConnectionNode) !void {
        var event = linux.epoll_event{
            .events = linux.POLL.IN,
            .data = .{ .ptr = @intFromPtr(node) },
        };
        try posix.epoll_ctl(
            self.efd,
            linux.EPOLL.CTL_ADD,
            node.data.socket,
            &event,
        );
    }

    fn setIoMode(self: *Epoll, node: *http.ConnectionNode, mode: Mode) !void {
        std.debug.assert(node.data.io_mode != mode);
        node.data.io_mode = mode;

        var event = linux.epoll_event{
            .events = switch (mode) {
                .read => linux.POLL.IN,
                .write => linux.POLL.OUT,
            },
            .data = .{ .ptr = @intFromPtr(node) },
        };

        try posix.epoll_ctl(
            self.efd,
            linux.EPOLL.CTL_MOD,
            node.data.socket,
            &event,
        );
    }
};

const KQueue = struct {
    kfd: i32,
    ready_list: [ready_list_len]posix.Kevent,

    pub const Iterator = struct {
        index: usize,
        ready_list: []posix.Kevent,

        pub fn next(self: *Iterator) ?Event {
            if (self.index == self.ready_list.len) return null;
            defer self.index += 1;

            const ready = self.ready_list[self.index];
            return switch (ready.udata) {
                0 => .accept,
                else => |nptr| ret: {
                    const node: *http.ConnectionNode = @alignCast(@as(
                        *http.ConnectionNode,
                        @ptrFromInt(nptr),
                    ));
                    if (ready.filter == posix.system.EVFILT.READ) {
                        break :ret .{ .read = node };
                    }
                    break :ret .{ .write = node };
                },
            };
        }
    };

    fn init() !KQueue {
        return KQueue{
            .kfd = try posix.kqueue(),
            .ready_list = undefined,
        };
    }

    fn deinit(self: *KQueue) void {
        posix.close(self.kfd);
    }

    fn addListener(self: *KQueue, listener: posix.socket_t) !void {
        _ = try posix.kevent(self.kfd, &.{
            .{
                .ident = @intCast(listener),
                .filter = posix.system.EVFILT.READ,
                .flags = posix.system.EV.ADD,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
        }, &.{}, null);
    }

    fn removeListener(self: *KQueue, listener: posix.socket_t) !void {
        try self.queueChange(.{
            .ident = @intCast(listener),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.DISABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });
    }

    fn wait(self: *KQueue) !Iterator {
        const count = try posix.kevent(self.kfd, &.{}, &self.ready_list, null);
        return Iterator{
            .index = 0,
            .ready_list = self.ready_list[0..count],
        };
    }

    fn newConnectionNode(self: *KQueue, node: *http.ConnectionNode) !void {
        try self.queueChange(.{
            .ident = @intCast(node.data.socket),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ADD,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(node),
        });

        try self.queueChange(.{
            .ident = @intCast(node.data.socket),
            .filter = posix.system.EVFILT.WRITE,
            .flags = posix.system.EV.ADD | posix.system.EV.DISABLE,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(node),
        });

        node.data.io_mode = .write;
        try self.setIoMode(node, .read);
    }

    fn readMode(self: *KQueue, node: *http.ConnectionNode) !void {
        try self.queueChange(.{
            .ident = @intCast(node.data.socket),
            .filter = posix.system.EVFILT.WRITE,
            .flags = posix.system.EV.DISABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });

        try self.queueChange(.{
            .ident = @intCast(node.data.socket),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(node),
        });
    }

    fn writeMode(self: *KQueue, node: *http.ConnectionNode) !void {
        try self.queueChange(.{
            .ident = @intCast(node.data.socket),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.DISABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });

        try self.queueChange(.{
            .ident = @intCast(node.data.socket),
            .flags = posix.system.EV.ENABLE,
            .filter = posix.system.EVFILT.WRITE,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(node),
        });
    }

    fn setIoMode(self: *KQueue, node: *http.ConnectionNode, mode: Mode) !void {
        std.debug.assert(node.data.io_mode != mode);
        node.data.io_mode = mode;
        switch (node.data.io_mode) {
            .write => try self.writeMode(node),
            .read => try self.readMode(node),
        }
    }

    // fn setIoMode(self: *KQueue, node: *http.ConnectionNode, mode: Mode) !void {
    //     std.debug.assert(node.data.io_mode != mode);
    //     node.data.io_mode = mode;
    //
    //     try self.queueChange(.{
    //         .ident = @intCast(node.data.socket),
    //         .filter = if (mode == .write) posix.system.EVFILT.READ else posix.system.EVFILT.WRITE,
    //         .flags = posix.system.EV.DISABLE,
    //         .fflags = 0,
    //         .data = 0,
    //         .udata = 0,
    //     });
    //
    //     try self.queueChange(.{
    //         .ident = @intCast(node.data.socket),
    //         .filter = if (mode == .write) posix.system.EVFILT.WRITE else posix.system.EVFILT.READ,
    //         .flags = posix.system.EV.ENABLE,
    //         .fflags = 0,
    //         .data = 0,
    //         .udata = @intFromPtr(node),
    //     });
    // }

    fn queueChange(self: *KQueue, event: posix.Kevent) !void {
        _ = try posix.kevent(self.kfd, &.{event}, &.{}, null);
    }
};

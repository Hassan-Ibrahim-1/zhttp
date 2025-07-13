const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const builtin = @import("builtin");

const http = @import("../http.zig");
pub const Scheduler = @import("Scheduler.zig");

const ready_list_len = 1024 * 10;

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

    pub fn shutdown(self: *EventLoop) Pipe.WriteError!void {
        try self.impl.shutdown();
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
    shutdown: void,
};

pub const Pipe = struct {
    /// first fd is the read pipe and the second fd is the write pipe
    fd: [2]posix.fd_t,

    const Error = posix.PipeError || posix.FcntlError;

    fn init() Error!Pipe {
        const fd = try posix.pipe();
        _ = try posix.fcntl(fd[0], posix.F.SETFL, posix.SOCK.NONBLOCK);
        return .{
            .fd = fd,
        };
    }

    fn deinit(self: *Pipe) void {
        posix.close(self.fd[0]);
        posix.close(self.fd[1]);
    }

    pub const WriteError = error{Closed} || posix.WriteError;

    fn write(self: *Pipe, bytes: []const u8) WriteError!void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const n = try posix.write(self.fd[1], bytes[pos..]);
            if (n == 0) return error.Closed;
            pos += n;
        }
    }
};

const listener_ptr: usize = 0;
const shutdown_ptr: usize = 1;

const Epoll = struct {
    efd: posix.fd_t,
    shutdown_pipe: Pipe,
    ready_list: [ready_list_len]linux.epoll_event = undefined,

    pub const Iterator = struct {
        index: usize,
        ready_list: []linux.epoll_event,

        pub fn next(self: *Iterator) ?Event {
            if (self.index == self.ready_list.len) return null;
            defer self.index += 1;

            const ready = self.ready_list[self.index];
            return switch (ready.data.ptr) {
                listener_ptr => .accept,
                shutdown_ptr => .shutdown,
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

    const EpollError = posix.EpollCreateError || Pipe.Error || posix.EpollCtlError;

    fn init() EpollError!Epoll {
        const efd = try posix.epoll_create1(0);
        const pipe = try Pipe.init();

        var event = linux.epoll_event{
            .data = .{ .ptr = shutdown_ptr },
            .events = linux.POLL.IN,
        };
        try posix.epoll_ctl(efd, linux.EPOLL.CTL_ADD, pipe.fd[0], &event);

        return Epoll{ .efd = efd, .shutdown_pipe = pipe };
    }

    fn deinit(self: *Epoll) void {
        posix.close(self.efd);
        self.shutdown_pipe.deinit();
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
            .data = .{ .ptr = listener_ptr },
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

    fn shutdown(self: *Epoll) Pipe.WriteError!void {
        try self.shutdown_pipe.write("x");
    }
};

const KQueue = struct {
    kfd: i32,
    shutdown_pipe: Pipe,
    ready_list: [ready_list_len]posix.Kevent,

    pub const Iterator = struct {
        index: usize,
        ready_list: []posix.Kevent,

        pub fn next(self: *Iterator) ?Event {
            if (self.index == self.ready_list.len) return null;
            defer self.index += 1;

            const ready = self.ready_list[self.index];
            return switch (ready.udata) {
                listener_ptr => .accept,
                shutdown_ptr => .shutdown,
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
        const kfd = try posix.kqueue();
        const pipe = try Pipe.init();

        try addPipe(kfd, pipe);

        return KQueue{
            .kfd = kfd,
            .shutdown_pipe = pipe,
            .ready_list = undefined,
        };
    }

    fn addPipe(kfd: posix.fd_t, pipe: Pipe) !void {
        _ = try posix.kevent(kfd, &.{
            .{
                .ident = @intCast(pipe.fd[0]),
                .filter = posix.system.EVFILT.READ,
                .flags = posix.system.EV.ADD,
                .fflags = 0,
                .data = 0,
                .udata = shutdown_ptr,
            },
        }, &.{}, null);
    }

    fn deinit(self: *KQueue) void {
        posix.close(self.kfd);
        self.shutdown_pipe.deinit();
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

    fn setIoMode(self: *KQueue, node: *http.ConnectionNode, mode: Mode) !void {
        std.debug.assert(node.data.io_mode != mode);
        node.data.io_mode = mode;

        try self.queueChange(.{
            .ident = @intCast(node.data.socket),
            .filter = if (mode == .write) posix.system.EVFILT.READ else posix.system.EVFILT.WRITE,
            .flags = posix.system.EV.DISABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });

        try self.queueChange(.{
            .ident = @intCast(node.data.socket),
            .filter = if (mode == .write) posix.system.EVFILT.WRITE else posix.system.EVFILT.READ,
            .flags = posix.system.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(node),
        });
    }

    fn queueChange(self: *KQueue, event: posix.Kevent) !void {
        _ = try posix.kevent(self.kfd, &.{event}, &.{}, null);
    }

    fn shutdown(self: *KQueue) Pipe.WriteError!void {
        try self.shutdown_pipe.write("x");
    }
};

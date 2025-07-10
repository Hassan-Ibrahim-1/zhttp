const std = @import("std");
const Allocator = std.mem.Allocator;

const http = @import("../http.zig");

const Scheduler = @This();

const worker_count = 8;

pub fn Queue(T: type) type {
    return struct {
        buf: std.ArrayList(T),

        const Self = @This();

        pub fn init(alloc: Allocator) Self {
            return .{
                .buf = .init(alloc),
            };
        }

        pub fn deinit(self: *Self) void {
            self.buf.deinit();
        }

        pub fn queue(self: *Self, item: T) Allocator.Error!void {
            try self.buf.append(item);
        }

        pub fn dequeue(self: *Self) ?T {
            if (self.buf.items.len == 0) return null;
            return self.buf.orderedRemove(0);
        }

        pub fn removeAt(self: *Self, i: usize) T {
            return self.buf.orderedRemove(i);
        }
    };
}

pub const ClientDispatchFn = *const fn (
    server: *http.Server,
    client: *http.Client,
    req: *const http.Request,
) void;

pub const Context = struct {
    server: *http.Server,
    client: *http.Client,
    req: *const http.Request,
};

queue: Queue(Context),
queue_mu: std.Thread.Mutex,
queue_cond: std.Thread.Condition,
workers: [worker_count]std.Thread,
running: bool,

dispatch: ClientDispatchFn,

pub fn init(
    alloc: std.mem.Allocator,
    comptime dispatch: ClientDispatchFn,
) Scheduler {
    return Scheduler{
        .queue = .init(alloc),
        .queue_mu = .{},
        .queue_cond = .{},
        .workers = undefined,
        .running = false,
        .dispatch = dispatch,
    };
}

pub fn deinit(self: *Scheduler) void {
    if (self.running) {
        for (self.workers) |worker| {
            worker.join();
        }
    }
    self.running = false;
    self.queue.deinit();
}

pub fn start(self: *Scheduler) !void {
    self.running = true;
    for (&self.workers) |*w| {
        w.* = try std.Thread.spawn(.{}, work, .{self});
    }
}

pub fn schedule(self: *Scheduler, context: Context) !void {
    self.queue_mu.lock();
    defer self.queue_mu.unlock();

    try self.queue.queue(context);
    self.queue_cond.signal();
}

pub fn unscheduleClient(self: *Scheduler, client: *http.Client) !void {
    self.queue_mu.lock();
    defer self.queue_mu.unlock();

    var iter = std.mem.reverseIterator(self.queue.buf.items);

    var i: usize = 0;
    var removed: usize = 0;
    while (iter.next()) |ctx| : (i += 1) {
        if (ctx.client == client) {
            _ = self.queue.removeAt(i - removed);
            removed += 1;
        }
    }
}

fn work(self: *Scheduler) void {
    while (self.running) {
        self.queue_mu.lock();
        while (self.queue.buf.items.len == 0) {
            self.queue_cond.wait(&self.queue_mu);
        }
        const context = self.queue.dequeue().?;
        self.queue_mu.unlock();

        if (!context.client.valid) {
            std.log.err("invalid client: {}", .{context.client.addr});
            @panic("OOPS");
        }
        self.dispatch(context.server, context.client, context.req);
    }
}

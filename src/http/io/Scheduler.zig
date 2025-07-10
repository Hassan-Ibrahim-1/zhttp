const std = @import("std");

const http = @import("../http.zig");

const Scheduler = @This();

const worker_count = 8;

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

queue: std.fifo.LinearFifo(Context, .Dynamic),
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

pub fn start(self: *Scheduler) !void {
    self.running = true;
    for (&self.workers) |*w| {
        w.* = try std.Thread.spawn(.{}, work, .{self});
    }
}

pub fn schedule(self: *Scheduler, context: Context) !void {
    self.queue_mu.lock();
    defer self.queue_mu.unlock();

    try self.queue.writeItem(context);
    self.queue_cond.signal();
}

pub fn deinit(self: *Scheduler) void {
    for (self.workers) |worker| {
        worker.join();
    }

    self.queue.deinit();
}

fn work(self: *Scheduler) void {
    while (self.running) {
        self.queue_mu.lock();
        while (self.queue.readableLength() == 0) {
            self.queue_cond.wait(&self.queue_mu);
        }
        const context = self.queue.readItem().?;
        self.queue_mu.unlock();

        self.dispatch(context.server, context.client, context.req);
    }
}

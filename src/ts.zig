const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

const cast = @import("cast.zig");

const log = std.log.scoped(.ts);
fn Job(T: type) type {
    return struct {
        task: T,
        run_at: i64,
    };
}

fn Scheduler(T: type) type {
    return struct {
        queue: Queue,
        mu: Mutex,
        cond: std.Thread.Condition,
        thread: ?std.Thread,

        const Queue = std.PriorityQueue(Job(T), void, compare);
        const Self = @This();

        fn compare(_: void, a: Job(T), b: Job(T)) std.math.Order {
            return std.math.order(a.run_at, b.run_at);
        }

        fn init(alloc: Allocator) Self {
            return Self{
                .queue = .init(alloc, {}),
                .mu = .{},
                .cond = .{},
                .thread = null,
            };
        }

        fn deinit(self: *Self) void {
            self.queue.deinit();
            self.stop();
        }

        fn schedule(self: *Self, task: T, run_at: i64) !void {
            self.mu.lock();
            defer self.mu.unlock();

            const reschedule: bool = re: {
                if (self.queue.peek()) |node| {
                    break :re node.run_at > run_at;
                }
                break :re true;
            };

            try self.queue.add(.{
                .task = task,
                .run_at = run_at,
            });

            if (reschedule) {
                self.cond.signal();
            }
        }

        fn scheduleIn(self: *Self, task: T, ms: i64) !void {
            return self.schedule(task, std.time.milliTimestamp() + ms);
        }

        fn start(self: *Self) !void {
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }

        fn stop(self: *Self) void {
            self.cond.signal();
            if (self.thread) |th| {
                th.join();
            }
        }

        fn run(self: *Self) void {
            while (true) {
                self.mu.lock();
                while (true) {
                    if (self.timeUntilNextTask()) |ms| {
                        if (ms > 0) {
                            const s: f32 = cast.f32(ms) / cast.f32(std.time.ms_per_s);
                            log.info("task scheduled in {d:.3}", .{s});
                            const ns: u64 = @intCast(ms * std.time.ns_per_ms);
                            self.cond.timedWait(&self.mu, ns) catch |err| {
                                std.debug.assert(err == error.Timeout);
                            };
                            continue;
                        }
                    } else {
                        log.info("no tasks scheduled", .{});
                        self.cond.wait(&self.mu);
                        continue;
                    }
                    break;
                }

                const next = self.queue.peek() orelse {
                    log.info("queue empty", .{});
                    self.mu.unlock();
                    continue;
                };

                if (next.run_at > std.time.milliTimestamp()) {
                    log.info("too early", .{});
                    self.mu.unlock();
                    continue;
                }

                const job = self.queue.remove();
                log.info("popping queue {any}", .{job});
                self.mu.unlock();
                job.task.run();
            }
        }

        fn timeUntilNextTask(self: *Self) ?i64 {
            if (self.queue.peek()) |*node| {
                return node.run_at - std.time.milliTimestamp();
            }
            return null;
        }
    };
}

const Task = union(enum) {
    say: Say,
    db_cleaner: void,

    fn run(task: Task) void {
        switch (task) {
            .say => |s| std.debug.print("{s} said {s}\n", .{ s.name, s.msg }),
            .db_cleaner => std.debug.print("cleaning db\n", .{}),
        }
    }
};

const Say = struct {
    name: []const u8,
    msg: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const alloc = gpa.allocator();

    var s = Scheduler(Task).init(alloc);
    defer s.deinit();

    try s.start();
    try s.scheduleIn(
        .{
            .say = .{
                .msg = "Whats up",
                .name = "Bebe",
            },
        },
        2000,
    );

    try s.scheduleIn(
        .{
            .say = .{
                .msg = "Meow",
                .name = "Pido",
            },
        },
        1000,
    );
}

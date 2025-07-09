const std = @import("std");

var mu: std.Thread.Mutex = .{};
var x: i32 = 0;
var start = false;
var sem: std.Thread.Semaphore = .{};

fn edit() void {
    while (!start) {}

    for (0..100) |_| {
        mu.lock();
        defer mu.unlock();
        const t = x;
        x = t + 1;
    }
}

fn a() void {
    std.debug.print("a starting\n", .{});
    sem.post();
}

fn b() void {
    sem.wait();
    std.debug.print("b ending\n", .{});
}

pub fn main() !void {
    const w = std.io.getStdOut().writer();
    _ = w; // autofix

    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const alloc = arena.allocator();
    _ = alloc; // autofix

    const th = try std.Thread.spawn(.{}, b, .{});
    a();

    th.join();
}

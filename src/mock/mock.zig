const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("../http/http.zig");
const log = std.log.scoped(.mock);

pub const request = @import("request.zig");

pub const TestFn = fn (alloc: Allocator) anyerror!void;

// TODO: custom allocator that doesn't report leaks twice
const MockAllocator = std.heap.DebugAllocator(.{});

const TestResult = union(enum) {
    pass: void,
    fail: anyerror,
};

/// The mock runner will find every function in T
/// that starts with 'test' and run it and expect that it doesn't return any error
/// Each test function must be of type TestFn
/// The mock runner will also check for memory leaks
pub fn run(T: type) void {
    const test_fns = extractTestFunctions(T);
    std.debug.print("Running tests for {s}\n", .{@typeName(T)});

    inline for (test_fns, 0..) |p, i| {
        const test_name = p.first;
        const testFn = p.second;
        switch (runTest(testFn)) {
            .pass => std.debug.print("[{}] {s}... Ok\n", .{ i + 1, test_name }),
            .fail => |err| {
                std.debug.print("[{}] {s}... Failed. Reason: {}\n", .{ i + 1, test_name, err });
                break;
            },
        }
    } else {
        std.debug.print("{} tests passed\n", .{test_fns.len});
    }
}

fn runTest(testFn: TestFn) TestResult {
    var gpa: MockAllocator = .init;
    testFn(gpa.allocator()) catch |err| return .{ .fail = err };
    if (gpa.deinit() != .ok) return .{ .fail = error.LeakedMemory };
    return .pass;
}

const TestFunctionDecl = Pair([]const u8, TestFn);

fn extractTestFunctions(T: type) []const TestFunctionDecl {
    const si = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        .@"enum" => |s| s,
        .@"union" => |s| s,
        else => |ti| compileError(
            "T must be a container type. got " ++ @tagName(ti),
        ),
    };

    var ret: []const TestFunctionDecl = &.{};
    for (si.decls) |decl| {
        if (!std.mem.startsWith(u8, decl.name, "test")) continue;

        const field = @field(T, decl.name);
        const FieldType = @TypeOf(field);
        switch (@typeInfo(FieldType)) {
            .@"fn" => |f| {
                const fn_path = @typeName(T) ++ "." ++ decl.name;
                if (f.params.len != 1) {
                    compileError(fn_path ++
                        " must have only one argument of type Allocator");
                }
                if (f.params[0].type.? != Allocator) {
                    compileError(fn_path ++
                        " must have only one argument of type Allocator");
                }
            },
            else => continue,
        }
        ret = ret ++ .{TestFunctionDecl.init(decl.name, field)};
    }
    return ret;
}

fn compileError(comptime msg: []const u8) noreturn {
    @compileError("(mock) " ++ msg);
}

pub fn Pair(F: type, S: type) type {
    return struct {
        const Self = @This();

        first: F,
        second: S,

        pub fn init(first: F, second: S) Self {
            return .{
                .first = first,
                .second = second,
            };
        }
    };
}

pub fn expectEqual(a: anytype, b: anytype) !void {
    const T = @TypeOf(a, b);
    switch (@typeInfo(T)) {
        .@"struct" => {
            switch (T) {
                http.Request => return expectEqualRequest(&a, &b),
                http.Request => return expectEqualRequest(&a, &b),
                else => {},
            }
        },
        .pointer => |p| {
            if (p.size == .one) {
                switch (p.child) {
                    http.Request => return expectEqualRequest(a, b),
                    http.Response => return expectEqualResponse(a, b),
                    else => {},
                }
            }
        },
        else => {},
    }
    return std.testing.expectEqual(a, b);
}

fn expectEqualRequest(a: *const http.Request, b: *const http.Request) !void {
    errdefer {
        std.debug.print("---------------------------------------------\n", .{});
        std.debug.print("Test failed: Unequal requests\n", .{});
        std.debug.print("Got:\n{}\n-----------Expected:\n{}\n", .{ a, b });
        std.debug.print("---------------------------------------------\n", .{});
    }

    if (a.protocol != b.protocol) {
        return error.UnequalRequests;
    }
    if (a.method != b.method) {
        return error.UnequalRequests;
    }
    if (!std.mem.eql(u8, a.url.raw, b.url.raw)) {
        return error.UnequalRequests;
    }
    if (!std.mem.eql(u8, a.body, b.body)) {
        return error.UnequalRequests;
    }
    if (!stringHashMapEql(&a.headers, &b.headers)) {
        return error.UnequalRequests;
    }
}

fn expectEqualResponse(a: *const http.Response, b: *const http.Response) !void {
    errdefer {
        std.debug.print("---------------------------------------------\n", .{});
        std.debug.print("Test failed: Unequal responses\n", .{});
        std.debug.print("Got:\n{}\n\n-----------\nExpected:\n{}\n\n", .{ a, b });
        std.debug.print("---------------------------------------------\n", .{});
    }

    if (a.protocol != b.protocol) {
        return error.UnequalResponses;
    }
    if (a.status_code != b.status_code) {
        return error.UnequalResponses;
    }
    if (!std.mem.eql(u8, a.body, b.body)) {
        return error.UnequalResponses;
    }
    if (!stringHashMapEql(&a.headers, &b.headers)) {
        return error.UnequalResponses;
    }
}

fn stringHashMapEql(
    a: *const std.StringHashMap([]const u8),
    b: *const std.StringHashMap([]const u8),
) bool {
    if (a.count() != a.count()) {
        return false;
    }
    var a_iter = a.iterator();
    var b_iter = b.iterator();
    for (0..a.count()) |_| {
        const akv = a_iter.next().?;
        const bkv = b_iter.next().?;

        if (!std.mem.eql(u8, akv.key_ptr.*, bkv.key_ptr.*)) {
            return false;
        }
        if (!std.mem.eql(u8, akv.value_ptr.*, bkv.value_ptr.*)) {
            return false;
        }
    }
    return true;
}

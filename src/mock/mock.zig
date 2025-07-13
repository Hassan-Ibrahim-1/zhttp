const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("../http/http.zig");
const log = std.log.scoped(.mock);
const utils = @import("utils.zig");
const Pair = utils.Pair;

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

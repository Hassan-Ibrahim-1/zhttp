const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("../http/http.zig");
const log = std.log.scoped(.mock);
const utils = @import("utils.zig");
const Pair = utils.Pair;

pub const request = @import("request.zig");

pub const TestFn = fn (alloc: Allocator) anyerror!void;

const Test = struct {
    pub fn testOk(alloc: Allocator) !void {
        _ = alloc;
        return;
    }

    pub fn testFail(alloc: Allocator) !void {
        _ = alloc;
        return error.TestFailed;
    }
};

/// T shouldn't have any fields. The mock runner will find every function
/// that starts with 'test' and run it and expect that it doesn't return any error
/// Each test function must be of type TestFn
/// The mock runner will also check for memory leaks
pub fn run(T: type) void {
    _ = T; // autofix
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();
    _ = alloc; // autofix

    const test_fns = comptime extractTestFunctions(Test);
    inline for (test_fns) |p| {
        log.info("found function {s}", .{p.first});
    }
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

    comptime {
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
}

fn compileError(comptime msg: []const u8) noreturn {
    @compileError("(mock) " ++ msg);
}

pub fn @"f32"(x: anytype) f32 {
    return switch (@typeInfo(@TypeOf(x))) {
        .int, .comptime_int => @floatFromInt(x),
        .float, .comptime_float => @floatCast(x),
        else => @compileError("Expected a float or integer"),
    };
}

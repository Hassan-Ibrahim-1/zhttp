const std = @import("std");

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

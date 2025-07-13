const std = @import("std");

const http = @import("../http.zig");

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!http.logging_enabled) return;

    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    const yellow = "\x1b[33m";
    const reset = "\x1b[0m";
    const red = "\x1b[31m";
    const orange = "\x1b[38;5;214m";

    const prefix = switch (message_level) {
        .debug,
        .info,
        => yellow ++ "info" ++ reset,
        .err => red ++ "err" ++ reset,
        .warn => orange ++ "warn" ++ reset,
    };
    const scope_prefix =
        if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    writer.print(prefix ++ scope_prefix ++ format ++ "\n", args) catch return;
    bw.flush() catch return;
}

pub fn info(
    comptime format: []const u8,
    args: anytype,
) void {
    log(.info, .default, format, args);
}

pub fn warn(
    comptime format: []const u8,
    args: anytype,
) void {
    log(.warn, .default, format, args);
}

pub fn err(
    comptime format: []const u8,
    args: anytype,
) void {
    log(.err, .default, format, args);
}

/// Same as info
pub fn debug(
    comptime format: []const u8,
    args: anytype,
) void {
    log(.debug, .default, format, args);
}

/// Returns a scoped logging namespace that logs all messages using the scope
/// provided here.
pub fn scoped(comptime scope: @Type(.enum_literal)) type {
    return struct {
        /// Log an error message. This log level is intended to be used
        /// when something has gone wrong. This might be recoverable or might
        /// be followed by the program exiting.
        pub fn err(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.err, scope, format, args);
        }

        /// Log a warning message. This log level is intended to be used if
        /// it is uncertain whether something has gone wrong or not, but the
        /// circumstances would be worth investigating.
        pub fn warn(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.warn, scope, format, args);
        }

        /// Log an info message. This log level is intended to be used for
        /// general messages about the state of the program.
        pub fn info(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.info, scope, format, args);
        }

        /// Log a debug message. This log level is intended to be used for
        /// messages which are only useful for debugging.
        pub fn debug(
            comptime format: []const u8,
            args: anytype,
        ) void {
            log(.debug, scope, format, args);
        }
    };
}

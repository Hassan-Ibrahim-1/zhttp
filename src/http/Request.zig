const std = @import("std");
const http = @import("http.zig");
const Allocator = std.mem.Allocator;

method: http.Method,
url: []const u8,
protocol: http.Protocol,
headers: std.StringHashMap([]const u8),
body: []const u8,
arena: Allocator,

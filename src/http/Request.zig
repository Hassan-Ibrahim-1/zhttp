const std = @import("std");
const Allocator = std.mem.Allocator;

const http = @import("http.zig");

method: http.Method,
url: http.Url,
protocol: http.Protocol,
headers: std.StringHashMap([]const u8),
body: []const u8,
arena: Allocator,

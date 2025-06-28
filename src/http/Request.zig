const std = @import("std");
const http = @import("http.zig");
const Allocator = std.mem.Allocator;

method: http.Method,
url: []u8,
protocol: http.Protocol,
headers: std.StringHashMap([]u8),
body: []u8,
arena: Allocator,

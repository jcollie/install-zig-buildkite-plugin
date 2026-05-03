// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const Data = @This();

const std = @import("std");
const builtin = @import("builtin");

const arch_os_string = std.fmt.comptimePrint("{t}-{t}", .{ builtin.cpu.arch, builtin.os.tag });
const ext = switch (builtin.target.os.tag) {
    .windows => ".zip",
    else => ".tar.xz",
};

version: std.SemanticVersion,
version_string: []const u8,
data: ?struct {
    tarball: []const u8,
    shasum: []const u8,
    size: u32,
} = null,

pub fn resolve(self: *const Data, alloc: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    const base_uri: std.Uri = try .parse(base_url);
    var uri_buf: [8192]u8 = undefined;

    const len = if (self.data) |data| len: {
        const tarball = try std.fmt.bufPrint(&uri_buf, "./{s}", .{data.tarball});
        break :len tarball.len;
    } else len: {
        const tarball = try std.fmt.bufPrint(&uri_buf, "./zig-{s}-{f}{s}", .{ arch_os_string, self.version, ext });
        break :len tarball.len;
    };

    var aux_buf: []u8 = &uri_buf;
    const uri = try std.Uri.resolveInPlace(base_uri, len, &aux_buf);

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try uri.writeToStream(&writer.writer, .all);
    return try writer.toOwnedSlice();
}

pub fn deinit(self: *const Data, alloc: std.mem.Allocator) void {
    alloc.free(self.version_string);
    if (self.data) |data| {
        alloc.free(data.tarball);
        alloc.free(data.shasum);
    }
}

// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const ZigArtifact = @This();

const std = @import("std");

const Data = @import("Data.zig");

tarball: []const u8,
shasum: []const u8,
size: u32,

pub fn deinit(self: *const ZigArtifact, alloc: std.mem.Allocator) void {
    alloc.free(self.tarball);
    alloc.free(self.shasum);
}

pub fn clone(self: *const ZigArtifact, alloc: std.mem.Allocator) !ZigArtifact {
    var tmp: ZigArtifact = undefined;
    tmp.tarball = try alloc.dupe(u8, self.tarball);
    errdefer alloc.free(tmp.tarball);
    tmp.shasum = try alloc.dupe(u8, self.shasum);
    errdefer alloc.free(tmp.shasum);
    tmp.size = self.size;
    return tmp;
}

pub fn data(self: *const ZigArtifact, alloc: std.mem.Allocator, version_string: []const u8) !Data {
    var tmp: Data = undefined;

    tmp.version_string = try alloc.dupe(u8, version_string);
    errdefer alloc.free(tmp.version_string);

    tmp.version = try .parse(tmp.version_string);

    const tarball = try alloc.dupe(u8, std.fs.path.basename(self.tarball));
    errdefer alloc.free(tarball);

    const shasum = try alloc.dupe(u8, self.shasum);
    errdefer alloc.free(shasum);

    tmp.data = .{
        .tarball = tarball,
        .shasum = shasum,
        .size = self.size,
    };

    return tmp;
}

// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const ZigRelease = @This();

const std = @import("std");

const ZigArtifact = @import("ZigArtifact.zig");

version: ?std.SemanticVersion = null,
version_string: ?[]const u8 = null,
date: ?[]const u8 = null,
docs: ?[]const u8 = null,
stdDocs: ?[]const u8 = null,
notes: ?[]const u8 = null,
artifacts: std.StringArrayHashMapUnmanaged(ZigArtifact) = .empty,

pub fn deinit(self: *ZigRelease, alloc: std.mem.Allocator) void {
    if (self.version_string) |v| alloc.free(v);
    if (self.date) |v| alloc.free(v);
    if (self.docs) |v| alloc.free(v);
    if (self.stdDocs) |v| alloc.free(v);
    if (self.notes) |v| alloc.free(v);
    var it = self.artifacts.iterator();
    while (it.next()) |kv| {
        kv.value_ptr.deinit(alloc);
        alloc.free(kv.key_ptr.*);
    }
    self.artifacts.deinit(alloc);
}

pub fn clone(self: *const ZigRelease, alloc: std.mem.Allocator) !ZigRelease {
    var tmp: ZigRelease = .{};
    errdefer tmp.deinit(alloc);

    if (self.version_string) |v| {
        const new_version_string = try alloc.dupe(u8, v);
        errdefer alloc.free(new_version_string);
        const new_version: std.SemanticVersion = try .parse(new_version_string);
        tmp.version_string = new_version_string;
        tmp.version = new_version;
    }
    if (self.date) |v| tmp.date = try alloc.dupe(u8, v);
    if (self.docs) |v| tmp.docs = try alloc.dupe(u8, v);
    if (self.stdDocs) |v| tmp.stdDocs = try alloc.dupe(u8, v);
    if (self.notes) |v| tmp.notes = try alloc.dupe(u8, v);
    var it = self.artifacts.iterator();
    while (it.next()) |entry| {
        const key = try alloc.dupe(u8, entry.key_ptr.*);
        const value = try entry.value_ptr.clone(alloc);
        try tmp.artifacts.putNoClobber(alloc, key, value);
    }
    return tmp;
}

pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ZigRelease {
    const parsed = try std.json.innerParse(std.json.Value, alloc, source, options);
    return ZigRelease.jsonParseFromValue(alloc, parsed, options);
}

pub fn jsonParseFromValue(arena_alloc: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !ZigRelease {
    if (source != .object) return error.UnexpectedToken;

    var tmp: ZigRelease = .{};

    var it = source.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const value = kv.value_ptr.*;
        if (std.mem.eql(u8, key, "version")) {
            if (value != .string) return error.UnexpectedToken;
            const new_version_string = try arena_alloc.dupe(u8, value.string);
            errdefer arena_alloc.free(new_version_string);
            const new_version = std.SemanticVersion.parse(new_version_string) catch return error.UnexpectedToken;
            tmp.version_string = new_version_string;
            tmp.version = new_version;
            continue;
        }
        if (std.mem.eql(u8, key, "date")) {
            if (value != .string) return error.UnexpectedToken;
            if (!isValidDate(value.string)) return error.UnexpectedToken;
            tmp.date = try arena_alloc.dupe(u8, value.string);
            continue;
        }
        if (std.mem.eql(u8, key, "docs")) {
            if (value != .string) return error.UnexpectedToken;
            tmp.docs = try arena_alloc.dupe(u8, value.string);
            continue;
        }
        if (std.mem.eql(u8, key, "stdDocs")) {
            if (value != .string) return error.UnexpectedToken;
            tmp.stdDocs = try arena_alloc.dupe(u8, value.string);
            continue;
        }
        if (std.mem.eql(u8, key, "notes")) {
            if (value != .string) return error.UnexpectedToken;
            tmp.notes = try arena_alloc.dupe(u8, value.string);
            continue;
        }
        if (value != .object) return error.UnexpectedToken;
        const artifact = try std.json.innerParseFromValue(ZigArtifact, arena_alloc, value, options);
        errdefer artifact.deinit(arena_alloc);
        const result = try tmp.artifacts.getOrPut(arena_alloc, key);
        if (!result.found_existing) {
            result.key_ptr.* = try arena_alloc.dupe(u8, key);
            result.value_ptr.* = artifact;
        } else {
            artifact.deinit(arena_alloc);
            result.value_ptr.* = artifact;
        }
    }

    return tmp;
}

fn isValidDate(str: []const u8) bool {
    if (str.len != 10) return false;
    if (str[4] != '-') return false;
    if (str[7] != '-') return false;
    if (std.mem.indexOfNone(u8, str[0..4], "0123456789")) |_| return false;
    if (std.mem.indexOfNone(u8, str[5..7], "0123456789")) |_| return false;
    if (std.mem.indexOfNone(u8, str[8..], "0123456789")) |_| return false;
    // TODO: check days per month
    return true;
}

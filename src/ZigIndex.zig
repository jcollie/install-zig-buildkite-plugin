const ZigIndex = @This();

const std = @import("std");

const minizign = @import("minizign");

const log = std.log.scoped(.index);

const ZigRelease = @import("ZigRelease.zig");

const index_url = "https://ziglang.org/download/index.json";
const public_key = minizign.PublicKey.decodeFromBase64("RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U") catch unreachable;

releases: std.StringArrayHashMapUnmanaged(ZigRelease) = .empty,

pub fn init(gpa: std.mem.Allocator, client: *std.http.Client) !ZigIndex {
    var index_writer: std.Io.Writer.Allocating = .init(gpa);
    defer index_writer.deinit();

    {
        log.info("downloading the release index", .{});
        const req = client.fetch(.{
            .method = .GET,
            .location = .{ .url = index_url },
            .response_writer = &index_writer.writer,
        }) catch |err| {
            log.err("unable to download the release index: {t}", .{err});
            return error.IndexError;
        };

        if (req.status != .ok) {
            log.err("unable to download the release index", .{});
            return error.IndexError;
        }
    }

    var scanner: std.json.Scanner = .initCompleteInput(gpa, index_writer.written());
    defer scanner.deinit();

    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);

    const parsed = std.json.parseFromTokenSource(ZigIndex, gpa, &scanner, .{}) catch |err| {
        log.err("parsing failed at {d}:{d} - {t}", .{ diag.getLine(), diag.getColumn(), err });
        return error.IndexParseError;
    };
    defer parsed.deinit();

    var it = parsed.value.releases.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "master")) continue;
        if (entry.value_ptr.version_string != null) continue;
        const alloc = parsed.arena.allocator();
        const new_version_string = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer alloc.free(new_version_string);
        const new_version: std.SemanticVersion = try .parse(new_version_string);
        entry.value_ptr.version_string = new_version_string;
        entry.value_ptr.version = new_version;
    }

    {
        log.info("downloading the release index signature", .{});
        const master = parsed.value.get(.master) orelse return error.NoMasterVersion;
        const signature_url = try std.fmt.allocPrint(
            gpa,
            "https://ziglang.org/builds/zig-{f}-index.json.minisig",
            .{master.version orelse return error.NoMasterVersion},
        );
        defer gpa.free(signature_url);

        var signature_writer: std.Io.Writer.Allocating = .init(gpa);
        defer signature_writer.deinit();

        const req = client.fetch(.{
            .method = .GET,
            .location = .{ .url = signature_url },
            .response_writer = &signature_writer.writer,
        }) catch |err| {
            log.warn("unable to download the release index signature: {t}", .{err});
            return error.IndexError;
        };

        if (req.status != .ok) {
            log.err("unable to download the release index signature: {t}", .{req.status});
            return error.IndexError;
        }

        var signature: minizign.Signature = try .decode(gpa, signature_writer.written());
        defer signature.deinit();

        var verifier = try public_key.verifier(&signature);
        verifier.update(index_writer.written());
        if (verifier.verify(gpa)) |_| {
            log.info("signature verification of the index succeeded!", .{});
        } else |err| {
            log.warn("signature verification of the index failed: {t}", .{err});
        }
    }

    return try parsed.value.clone(gpa);
}

pub fn deinit(self: *ZigIndex, gpa: std.mem.Allocator) void {
    var it = self.releases.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        entry.value_ptr.deinit(gpa);
    }
    self.releases.deinit(gpa);
}

pub fn clone(self: *const ZigIndex, gpa: std.mem.Allocator) !ZigIndex {
    var tmp: ZigIndex = .{};
    var it = self.releases.iterator();
    while (it.next()) |entry| {
        const key = try gpa.dupe(u8, entry.key_ptr.*);
        errdefer gpa.free(key);
        var value = try entry.value_ptr.clone(gpa);
        errdefer value.deinit(gpa);
        try tmp.releases.putNoClobber(gpa, key, value);
    }
    return tmp;
}

pub const Version = union(enum) {
    master: void,
    latest: void,
    version: []const u8,
};

pub fn get(self: *const ZigIndex, version: Version) ?*const ZigRelease {
    switch (version) {
        .master => return self.releases.getPtr("master"),
        .latest => {
            var latest_: ?*ZigRelease = null;

            var it = self.releases.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "master")) continue;
                if (latest_) |latest| {
                    const old_version = latest.version orelse continue;
                    const new_version = entry.value_ptr.version orelse continue;
                    if (old_version.order(new_version) == .lt) {
                        latest_ = entry.value_ptr;
                    }
                } else {
                    latest_ = entry.value_ptr;
                }
            }

            return latest_;
        },
        .version => |v| return self.releases.getPtr(v),
    }
}

pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ZigIndex {
    const parsed = try std.json.innerParse(std.json.Value, alloc, source, options);
    if (parsed != .object) return error.UnexpectedToken;

    var tmp: ZigIndex = .{};

    var it = parsed.object.iterator();
    while (it.next()) |kv| {
        const version = kv.key_ptr.*;
        const value = kv.value_ptr.*;

        if (value != .object) return error.UnexpectedToken;

        var release = try std.json.innerParseFromValue(ZigRelease, alloc, value, .{});
        errdefer release.deinit(alloc);

        const result = try tmp.releases.getOrPut(alloc, version);
        if (!result.found_existing) {
            result.key_ptr.* = try alloc.dupe(u8, version);
            result.value_ptr.* = release;
        } else {
            result.value_ptr.*.deinit(alloc);
            result.value_ptr.* = release;
        }
    }

    return tmp;
}

// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const Mirrors = @This();

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.mirrors);

const Data = @import("Data.zig");
const TmpDir = @import("TmpDir.zig");

const zig_executable = switch (builtin.os.tag) {
    .windows => "zig.exe",
    else => "zig",
};

const mirrors_url = "https://ziglang.org/download/community-mirrors.txt";

// if the canonical mirror list is unavailable (perhaps because ziglang.org is
// down) use these mirrors:
const fallback_mirrors: []const []const u8 = &.{
    "https://pkg.machengine.org/zig",
    "https://zigmirror.hryx.net/zig",
    "https://zig.linus.dev/zig",
    "https://zig.squirl.dev",
    "https://zig.florent.dev",
    "https://zig.mirror.mschae23.de/zig",
    "https://zigmirror.meox.dev",
    "https://ziglang.freetls.fastly.net",
    "https://zig.tilok.dev",
    "https://zig-mirror.tsimnet.eu/zig",
    "https://zig.karearl.com/zig",
    "https://pkg.earth/zig",
    "https://fs.liujiacai.net/zigbuilds",
};

mirrors: []const []const u8,

pub fn init(io: std.Io, gpa: std.mem.Allocator, client: *std.http.Client) !Mirrors {
    var mirror_arena: std.heap.ArenaAllocator = .init(gpa);
    defer mirror_arena.deinit();

    const raw_mirrors = mirrors: {
        const alloc = mirror_arena.allocator();

        var writer: std.Io.Writer.Allocating = .init(gpa);
        defer writer.deinit();

        log.info("getting the list of community mirrors", .{});

        const req = client.fetch(.{
            .method = .GET,
            .location = .{ .url = mirrors_url },
            .response_writer = &writer.writer,
        }) catch |err| {
            log.warn("using fallback mirror list: zig error {t}", .{err});
            break :mirrors fallback_mirrors;
        };

        if (req.status != .ok) {
            log.warn("using fallback mirror list: http error {t}", .{req.status});
            break :mirrors fallback_mirrors;
        }

        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, writer.written(), '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (line.len == 0) continue;
            try list.append(alloc, if (std.mem.endsWith(u8, line, "/")) try alloc.dupe(u8, line) else try std.fmt.allocPrint(alloc, "{s}/", .{line}));
        }
        break :mirrors try list.toOwnedSlice(alloc);
    };

    const mirrors = try gpa.alloc([]const u8, raw_mirrors.len);
    for (raw_mirrors, 0..) |mirror, i| {
        if (std.mem.endsWith(u8, mirror, "/")) {
            mirrors[i] = try gpa.dupe(u8, mirror);
        } else {
            mirrors[i] = try std.fmt.allocPrint(gpa, "{s}/", .{mirror});
        }
    }

    const rng_impl: std.Random.IoSource = .{ .io = io };
    const rng = rng_impl.interface();
    rng.shuffle([]const u8, mirrors);

    return .{
        .mirrors = mirrors,
    };
}

pub fn deinit(self: *const Mirrors, gpa: std.mem.Allocator) void {
    defer {
        for (self.mirrors) |mirror| gpa.free(mirror);
        gpa.free(self.mirrors);
    }
}

const Hasher = std.crypto.hash.sha2.Sha256;

pub fn download(
    self: *const Mirrors,
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    client: *std.http.Client,
    data: *const Data,
) !std.meta.Tuple(&.{ []const u8, []const u8 }) {
    const tmpdir: TmpDir = try .init(io, gpa, env_map, .{});
    defer tmpdir.deinit(io, gpa);

    for (self.mirrors) |mirror| {
        const url = try data.resolve(gpa, mirror);
        defer gpa.free(url);

        log.info("attempting download from {s}", .{url});

        const uri: std.Uri = try .parse(url);

        var artifact_writer: std.Io.Writer.Allocating = .init(gpa);
        defer artifact_writer.deinit();

        var hash_buffer: [1024]u8 = undefined;
        var hasher: std.Io.Writer.Hashed(Hasher) = .initHasher(&artifact_writer.writer, .init(.{}), &hash_buffer);

        const req = client.fetch(
            .{
                .method = .GET,
                .location = .{ .uri = uri },
                .response_writer = &hasher.writer,
            },
        ) catch |err| {
            log.warn("unable to download: {t}", .{err});
            continue;
        };

        if (req.status != .ok) {
            log.warn("unable to download: {t}", .{req.status});
            continue;
        }

        checks: {
            const d = data.data orelse break :checks;

            if (d.size != artifact_writer.written().len) return error.SizeMismatch;

            var expected_buffer: [Hasher.digest_length]u8 = undefined;
            const expected = try std.fmt.hexToBytes(&expected_buffer, d.shasum);

            const actual = hasher.hasher.finalResult();

            if (!std.mem.eql(u8, expected, &actual)) return error.HashMismatch;
        }

        switch (builtin.os.tag) {
            .windows => {
                const ziptmp: TmpDir = try .init(io, gpa, env_map, .{ .delete_on_deinit = true });
                defer ziptmp.deinit(io, gpa);

                try ziptmp.dir.writeFile(io, .{
                    .sub_path = "zig.zip",
                    .data = artifact_writer.written(),
                    .flags = .{
                        .exclusive = true,
                    },
                });

                const zipfile = try ziptmp.dir.openFile(io, "zig.zip", .{});
                defer zipfile.close(io);

                var read_buffer: [1024]u8 = undefined;
                var reader = zipfile.reader(io, &read_buffer);

                try std.zip.extract(tmpdir.dir, &reader, .{});
            },
            else => {
                var reader: std.Io.Reader = .fixed(artifact_writer.written());
                const xz_buffer = try gpa.alloc(u8, 1024);
                var xz: std.compress.xz.Decompress = try .init(&reader, gpa, xz_buffer);
                defer xz.deinit();
                try std.tar.extract(io, tmpdir.dir, &xz.reader, .{});
            },
        }
        break;
    }

    var it = tmpdir.dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                const subdir = try tmpdir.dir.openDir(io, entry.name, .{});
                const stat = subdir.statFile(io, zig_executable, .{}) catch {
                    continue;
                };
                switch (stat.kind) {
                    .file => {
                        subdir.access(io, zig_executable, .{ .execute = true }) catch |err| {
                            log.warn("zig executable doesn not appear to be executable: {t}", .{err});
                            continue;
                        };
                        const dir = try std.fs.path.join(gpa, &.{ tmpdir.path, entry.name });
                        errdefer gpa.free(dir);
                        const path = try std.fs.path.join(gpa, &.{ tmpdir.path, entry.name, zig_executable });
                        errdefer gpa.free(path);
                        return .{ dir, path };
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    return error.ZigExecutableNotFound;
}

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.zig_install);

const mirrors_url = "https://ziglang.org/download/community-mirrors.txt";
const versions_url = "https://ziglang.org/download/index.json";

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

const arch_os_string = std.fmt.comptimePrint("{t}-{t}", .{ builtin.cpu.arch, builtin.os.tag });

const ext = switch (builtin.target.os.tag) {
    .windows => ".zip",
    else => ".tar.xz",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var client: std.http.Client = .{
        .io = io,
        .allocator = gpa,
    };
    defer client.deinit();

    const mirrors = try getMirrors(gpa, &client);
    defer {
        for (mirrors) |mirror| gpa.free(mirror);
        gpa.free(mirrors);
    }

    const rng_impl: std.Random.IoSource = .{ .io = io };
    const rng = rng_impl.interface();
    rng.shuffle([]const u8, mirrors);

    for (mirrors) |mirror| {
        log.warn("mirror: {s}", .{mirror});
    }

    const data: Data = version: {
        const requested_version = init.environ_map.get("BUILDKITE_PLUGIN_INSTALL_ZIG_VERSION") orelse "latest";

        var writer: std.Io.Writer.Allocating = .init(gpa);
        defer writer.deinit();

        const req = try client.fetch(.{
            .method = .GET,
            .location = .{ .url = versions_url },
            .response_writer = &writer.writer,
        });

        if (req.status != .ok) return error.NoVersion;
        var scanner: std.json.Scanner = .initCompleteInput(gpa, writer.written());
        defer scanner.deinit();

        var diag: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&diag);

        const parsed = std.json.parseFromTokenSource(ZigIndex, gpa, &scanner, .{}) catch |err| {
            log.err("parsing failed at {d}:{d} - {t}", .{ diag.getLine(), diag.getColumn(), err });
            return;
        };
        defer parsed.deinit();

        const release_ = release: {
            if (std.mem.eql(u8, requested_version, "master")) {
                break :release parsed.value.releases.getPtr("master") orelse return error.NoMasterVersion;
            }

            if (std.mem.eql(u8, requested_version, "latest")) {
                var latest_: ?*ZigRelease = null;

                var it = parsed.value.releases.iterator();
                while (it.next()) |entry| {
                    const version_string = entry.key_ptr.*;
                    if (std.mem.eql(u8, version_string, "master")) continue;
                    if (latest_) |latest| {
                        const latest_string = latest.version orelse continue;
                        const old_version: std.SemanticVersion = try .parse(latest_string);
                        const version: std.SemanticVersion = try .parse(version_string);
                        if (old_version.order(version) == .lt) {
                            latest_ = entry.value_ptr;
                        }
                    } else {
                        latest_ = entry.value_ptr;
                    }
                }
                if (latest_) |latest| {
                    break :release latest;
                }
            }

            break :release parsed.value.releases.getPtr(requested_version);
        };

        if (release_) |release| {
            const version_string = release.version orelse return error.NoReleaseVersion;
            const artifact = release.artifacts.get(arch_os_string) orelse return error.NoArtifact;
            break :version try artifact.data(gpa, version_string);
        }

        if (std.SemanticVersion.parse(requested_version)) |_| {
            const version_string = try gpa.dupe(u8, requested_version);
            errdefer gpa.free(version_string);
            const version: std.SemanticVersion = try .parse(version_string);
            break :version .{
                .version = version,
                .version_string = version_string,
            };
        } else |_| {
            return error.UnknownVersion;
        }
    };
    defer data.deinit(gpa);

    log.warn("{f}", .{data.version});

    {
        for (mirrors) |mirror| {
            const url = try data.resolve(gpa, mirror);
            defer gpa.free(url);
            log.warn("url: {s}", .{url});
        }
    }
    try stdout_writer.flush(); // Don't forget to flush!
}

pub const ZigIndex = struct {
    releases: std.StringArrayHashMapUnmanaged(ZigRelease) = .empty,

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
};

pub const ZigRelease = struct {
    version: ?[]const u8 = null,
    date: ?[]const u8 = null,
    docs: ?[]const u8 = null,
    stdDocs: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    artifacts: std.StringArrayHashMapUnmanaged(ZigArtifact) = .empty,

    pub fn deinit(self: *ZigRelease, alloc: std.mem.Allocator) void {
        if (self.version) |v| alloc.free(v);
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

    pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ZigRelease {
        const parsed = try std.json.innerParse(std.json.Value, alloc, source, options);
        return ZigRelease.jsonParseFromValue(alloc, parsed, options);
    }

    pub fn jsonParseFromValue(alloc: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !ZigRelease {
        if (source != .object) return error.UnexpectedToken;

        var tmp: ZigRelease = .{};

        var it = source.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const value = kv.value_ptr.*;
            if (std.mem.eql(u8, key, "version")) {
                if (value != .string) return error.UnexpectedToken;
                _ = std.SemanticVersion.parse(value.string) catch return error.UnexpectedToken;
                tmp.version = try alloc.dupe(u8, value.string);
                continue;
            }
            if (std.mem.eql(u8, key, "date")) {
                if (value != .string) return error.UnexpectedToken;
                if (!isValidDate(value.string)) return error.UnexpectedToken;
                tmp.date = try alloc.dupe(u8, value.string);
                continue;
            }
            if (std.mem.eql(u8, key, "docs")) {
                if (value != .string) return error.UnexpectedToken;
                tmp.docs = try alloc.dupe(u8, value.string);
                continue;
            }
            if (std.mem.eql(u8, key, "stdDocs")) {
                if (value != .string) return error.UnexpectedToken;
                tmp.stdDocs = try alloc.dupe(u8, value.string);
                continue;
            }
            if (std.mem.eql(u8, key, "notes")) {
                if (value != .string) return error.UnexpectedToken;
                tmp.notes = try alloc.dupe(u8, value.string);
                continue;
            }
            if (value != .object) return error.UnexpectedToken;
            const artifact = try std.json.innerParseFromValue(ZigArtifact, alloc, value, options);
            errdefer artifact.deinit(alloc);
            const result = try tmp.artifacts.getOrPut(alloc, key);
            if (!result.found_existing) {
                result.key_ptr.* = try alloc.dupe(u8, key);
                result.value_ptr.* = artifact;
            } else {
                alloc.free(artifact.tarball);
                alloc.free(artifact.shasum);
                result.value_ptr.* = artifact;
            }
        }

        return tmp;
    }
};

pub const Data = struct {
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
};

pub const ZigArtifact = struct {
    tarball: []const u8,
    shasum: []const u8,
    size: u32,

    pub fn data(self: *const ZigArtifact, alloc: std.mem.Allocator, version_string: []const u8) !Data {
        const v = try alloc.dupe(u8, version_string);
        errdefer alloc.free(v);
        const v1: std.SemanticVersion = try .parse(v);
        const tarball = try alloc.dupe(u8, std.fs.path.basename(self.tarball));
        errdefer alloc.free(tarball);
        const shasum = try alloc.dupe(u8, self.shasum);
        return .{
            .version = v1,
            .version_string = v,
            .data = .{
                .tarball = tarball,
                .shasum = shasum,
                .size = self.size,
            },
        };
    }

    pub fn deinit(self: *const ZigArtifact, alloc: std.mem.Allocator) void {
        alloc.free(self.tarball);
        alloc.free(self.shasum);
    }
};

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

pub fn getMirrors(gpa: std.mem.Allocator, client: *std.http.Client) ![][]const u8 {
    var mirror_arena: std.heap.ArenaAllocator = .init(gpa);
    defer mirror_arena.deinit();

    const raw_mirrors = mirrors: {
        const alloc = mirror_arena.allocator();

        var writer: std.Io.Writer.Allocating = .init(gpa);
        defer writer.deinit();

        const req = client.fetch(.{
            .method = .GET,
            .location = .{ .url = mirrors_url },
            .response_writer = &writer.writer,
        }) catch |err| {
            log.warn("err: {t}", .{err});
            break :mirrors fallback_mirrors;
        };

        if (req.status != .ok) break :mirrors fallback_mirrors;

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

    return mirrors;
}

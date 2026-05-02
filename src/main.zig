const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.install);

const arch_os_string = std.fmt.comptimePrint("{t}-{t}", .{ builtin.cpu.arch, builtin.os.tag });

const Data = @import("Data.zig");
const ZigIndex = @import("ZigIndex.zig");
const ZigRelease = @import("ZigRelease.zig");
const Mirrors = @import("Mirrors.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var client: std.http.Client = .{
        .io = io,
        .allocator = gpa,
    };
    defer client.deinit();

    const mirrors: Mirrors = try .init(io, gpa, &client);
    defer mirrors.deinit(gpa);

    var index: ZigIndex = try .init(gpa, &client);
    defer index.deinit(gpa);

    const data: Data = version: {
        const requested_version = init.environ_map.get("BUILDKITE_PLUGIN_INSTALL_ZIG_VERSION") orelse "latest";

        const release_ = release: {
            if (std.mem.eql(u8, requested_version, "master")) {
                break :release index.get(.master) orelse return error.NoMasterVersion;
            }

            if (std.mem.eql(u8, requested_version, "latest")) {
                break :release index.get(.latest) orelse return error.NoLatestVersion;
            }

            break :release index.get(.{ .version = requested_version });
        };

        if (release_) |release| {
            const version_string = release.version_string orelse return error.NoReleaseVersion;
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

    log.info("selected version {f}", .{data.version});

    const dir, const executable = try mirrors.download(io, gpa, init.environ_map, &client, &data);
    defer gpa.free(dir);
    defer gpa.free(executable);
    log.info("new path: {s}", .{dir});
    log.info("new zig executable: {s}", .{executable});

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("PATH={s}", .{dir});
    if (init.environ_map.get("PATH")) |path| {
        var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
        while (it.next()) |item| {
            try stdout.writeByte(std.fs.path.delimiter);
            try stdout.writeAll(item);
        }
    }
    try stdout.writeByte('\n');
    try stdout.writeAll("export PATH\n");
    try stdout.flush();
}

const TmpDir = @This();

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32").everything;

/// The basename of our temporary directory
sub_path: []const u8,
/// The absolute path to our temporary directory
path: []const u8,
/// Open directory handle to our temporary directory
dir: std.Io.Dir,
/// Open directory handle to the global temporary directory
tmp: std.Io.Dir,

delete_on_deinit: bool,

const random_basename_bytes = 16;
const b64_encoder = std.base64.url_safe_no_pad.Encoder;
pub const random_basename_len = b64_encoder.calcSize(random_basename_bytes);

pub const Options = struct {
    delete_on_deinit: bool = false,
};

pub fn init(io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map, options: Options) !TmpDir {
    const tmppath = switch (builtin.os.tag) {
        .windows => windows: {
            // GetTempPathW guarantees the result fits in MAX_PATH+1.
            var buf: [win32.MAX_PATH + 1:0]u16 = undefined;
            const len = win32.GetTempPathW(buf.len, &buf);
            if (len > 0) {
                // Trim the UTF-16 string before encoding as UTF-8 so that the
                // returned slice's length matches its underlying allocation.
                const trimmed = std.mem.trimEnd(u16, buf[0..len], &.{std.fs.path.sep});
                break :windows try std.unicode.utf16LeToUtf8Alloc(alloc, trimmed);
            }
            break :windows try alloc.dupe(u8, "C:\\Windows\\Temp");
        },
        else => posix: {
            const tmpdir = tmpdir: {
                if (env_map.get("TMPDIR")) |tmpdir| break :tmpdir tmpdir;
                if (env_map.get("TMP")) |tmpdir| break :tmpdir tmpdir;
                if (env_map.get("TEMP")) |tmpdir| break :tmpdir tmpdir;
                if (env_map.get("TEMPDIR")) |tmpdir| break :tmpdir tmpdir;
                break :tmpdir "/tmp";
            };
            break :posix std.mem.trimEnd(u8, tmpdir, &.{std.fs.path.sep});
        },
    };
    defer {
        switch (builtin.os.tag) {
            .windows => alloc.free(tmppath),
            else => {},
        }
    }

    const prefix = "tmp.";
    var random_bytes: [random_basename_bytes]u8 = undefined;
    io.random(&random_bytes);
    var sub_path_buffer: [prefix.len + random_basename_len]u8 = undefined;
    @memcpy(sub_path_buffer[0..prefix.len], prefix);

    _ = b64_encoder.encode(sub_path_buffer[prefix.len..], &random_bytes);
    const sub_path = try alloc.dupe(u8, &sub_path_buffer);
    errdefer alloc.free(sub_path);

    const path = try std.fs.path.join(alloc, &.{ tmppath, sub_path });
    errdefer alloc.free(path);

    const tmp = try std.Io.Dir.openDirAbsolute(io, tmppath, .{});
    errdefer tmp.close(io);

    const dir = try tmp.createDirPathOpen(
        io,
        &sub_path_buffer,
        .{
            .open_options = .{ .iterate = true },
        },
    );
    errdefer dir.close(io);

    return .{
        .sub_path = sub_path,
        .path = path,
        .dir = dir,
        .tmp = tmp,
        .delete_on_deinit = options.delete_on_deinit,
    };
}

pub fn deinit(self: *const @This(), io: std.Io, alloc: std.mem.Allocator) void {
    self.dir.close(io);
    if (self.delete_on_deinit) {
        self.tmp.deleteTree(io, self.sub_path) catch {};
    }
    self.tmp.close(io);
    alloc.free(self.sub_path);
    alloc.free(self.path);
}

// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Writer that escapes characters that shells treat specially to reduce the
//! risk of injection attacks or other such weirdness.

const BashDoubleQuotedStringWriter = @This();

const std = @import("std");

interface: std.Io.Writer,
child: *std.Io.Writer,

pub fn init(child: *std.Io.Writer, buffer: []u8) BashDoubleQuotedStringWriter {
    return .{
        .interface = .{
            .buffer = buffer,
            .vtable = &.{
                .drain = VTable.drain,
                .flush = VTable.flush,
            },
        },
        .child = child,
    };
}

/// Keep the writer vtable implementations here to keep them organized in a separate namespace.
const VTable = struct {
    fn drain(interface: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BashDoubleQuotedStringWriter = @fieldParentPtr("interface", interface);

        var count: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            try self.write(chunk, &count);
        }

        for (0..splat) |_| {
            try self.write(data[data.len - 1], &count);
        }

        return count;
    }

    fn flush(interface: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *BashDoubleQuotedStringWriter = @fieldParentPtr("interface", interface);
        try self.flush();
    }
};

fn write(self: *BashDoubleQuotedStringWriter, chunk: []const u8, count: *usize) std.Io.Writer.Error!void {
    if (self.interface.buffer.len == 0) {
        try self.writeEscaped(chunk);
        return;
    }

    var index: usize = 0;

    while (index < chunk.len) {
        const size = @min(
            self.interface.buffer.len - self.interface.end,
            chunk.len - index,
        );

        @memcpy(
            self.interface.buffer[self.interface.end .. self.interface.end + size],
            chunk[index .. index + size],
        );

        self.interface.end += size;
        index += size;
        count.* += size;

        if (self.interface.buffer.len == self.interface.end) try self.flush();
    }
}

fn flush(self: *BashDoubleQuotedStringWriter) std.Io.Writer.Error!void {
    if (self.interface.buffer.len == 0) return;
    try self.writeEscaped(self.interface.buffer[0..self.interface.end]);
    self.interface.end = 0;
}

fn writeEscaped(
    self: *BashDoubleQuotedStringWriter,
    chunk: []const u8,
) std.Io.Writer.Error!void {
    for (chunk) |byte| {
        // https://www.gnu.org/software/bash/manual/html_node/Double-Quotes.html
        const buf = switch (byte) {
            '$',
            '`',
            '"',
            '\n',
            '!',
            '\\',
            => &[_]u8{ '\\', byte },
            else => &[_]u8{byte},
        };
        try self.child.writeAll(buf);
    }
}

test "shell escape 1" {
    var writer_buf: [128]u8 = undefined;
    var shell_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_buf);
    var shell: BashDoubleQuotedStringWriter = .init(&writer, .bash, &shell_buf);
    try shell.interface.writeAll("abc");
    try shell.interface.flush();
    try std.testing.expectEqualStrings("abc", writer.buffered());
}

test "shell escape 2" {
    var writer_buf: [128]u8 = undefined;
    var shell_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_buf);
    var shell: BashDoubleQuotedStringWriter = .init(&writer, .bash, &shell_buf);
    try shell.interface.writeAll("a c");
    try shell.interface.flush();
    try std.testing.expectEqualStrings("a c", writer.buffered());
}

test "shell escape 3" {
    var writer_buf: [128]u8 = undefined;
    var shell_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_buf);
    var shell: BashDoubleQuotedStringWriter = .init(&writer, .bash, &shell_buf);
    try shell.interface.writeAll("a$c");
    try shell.interface.flush();
    try std.testing.expectEqualStrings("a\\$c", writer.buffered());
}

test "shell escape 4" {
    var writer_buf: [128]u8 = undefined;
    var shell_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_buf);
    var shell: BashDoubleQuotedStringWriter = .init(&writer, .bash, &shell_buf);
    try shell.interface.writeAll("a\\c");
    try shell.interface.flush();
    try std.testing.expectEqualStrings("a\\\\c", writer.buffered());
}

test "shell escape 5" {
    var writer_buf: [128]u8 = undefined;
    var shell_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_buf);
    var shell: BashDoubleQuotedStringWriter = .init(&writer, .bash, &shell_buf);
    try shell.interface.writeAll("a`c");
    try shell.interface.flush();
    try std.testing.expectEqualStrings("a\\`c", writer.buffered());
}

test "shell escape 6" {
    var writer_buf: [128]u8 = undefined;
    var shell_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_buf);
    var shell: BashDoubleQuotedStringWriter = .init(&writer, .bash, &shell_buf);
    try shell.interface.writeAll("a\"c");
    try shell.interface.flush();
    try std.testing.expectEqualStrings("a\\\"c", writer.buffered());
}

test "shell escape 7" {
    var writer_buf: [128]u8 = undefined;
    var shell_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_buf);
    var shell: BashDoubleQuotedStringWriter = .init(&writer, .bash, &shell_buf);
    try shell.interface.writeAll("a(1)");
    try shell.interface.flush();
    try std.testing.expectEqualStrings("a(1)", writer.buffered());
}

test "shell escape 8" {
    var writer_buf: [128]u8 = undefined;
    var shell_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&writer_buf);
    var shell: BashDoubleQuotedStringWriter = .init(&writer, .bash, &shell_buf);
    try shell.interface.writeAll("a!b");
    try shell.interface.flush();
    try std.testing.expectEqualStrings("a\\!b", writer.buffered());
}

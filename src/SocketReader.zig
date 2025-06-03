fd: usize,
cursor: usize = 0,
exhausted: bool = false,
buffer: *ArrayList,

pub fn readUntil(self: *@This(), delimiter: u8) SocketError![]u8 {
    if (self.readUntilWithinBuffer(delimiter)) |slice| return slice;

    var chunk: [100]u8 = undefined;
    while (!self.exhausted) {
        const read_count = try readFromSocket(self.fd, &chunk);
        if (read_count <= 0) {
            self.exhausted = true;
            break;
        }
        self.buffer.appendAll(chunk[0..@intCast(read_count)]);
        if (read_count < chunk.len) self.exhausted = true;
    }

    if (self.readUntilWithinBuffer(delimiter)) |slice| return slice;

    return self.buffer.items[self.cursor..];
}

pub fn readExact(self: *@This(), count: u16) SocketError![]u8 {
    if (self.readExactWithinBuffer(count)) |slice| return slice;

    var chunk: [100]u8 = undefined;
    while (!self.exhausted) {
        const read_count = try readFromSocket(self.fd, &chunk);
        if (read_count <= 0) {
            self.exhausted = true;
            break;
        }
        self.buffer.appendAll(chunk[0..@intCast(read_count)]);
        if (read_count < chunk.len) self.exhausted = true;
    }
    if (self.readExactWithinBuffer(count)) |slice| return slice;
    return self.buffer.items[self.cursor..];
}

fn readExactWithinBuffer(self: *@This(), count: u16) ?[]u8 {
    if (self.cursor + count > self.buffer.items.len) return null;

    const slice = self.buffer.items[self.cursor .. self.cursor + @as(usize, @intCast(count))];
    self.cursor += @intCast(count);
    return slice;
}

fn readUntilWithinBuffer(self: *@This(), delimiter: u8) ?[]u8 {
    for (self.buffer.items[self.cursor..], 1..) |it, count| {
        if (it == delimiter) {
            const slice = self.buffer.items[self.cursor .. self.cursor + count];
            self.cursor += count;
            return slice;
        }
    }
    return null;
}

fn readFromSocket(fd: usize, buffer: []u8) SocketError!usize {
    const read_count = c.read(@intCast(fd), buffer[0..buffer.len].ptr, buffer.len);
    const result = posix.errno(read_count);
    if (result != .SUCCESS) return SocketError.ReadFailed;
    return @intCast(read_count);
}

fn sendToSocket(fd: usize, bytes: []const u8) SocketError!usize {
    const result = posix.errno(c.send(@intCast(fd), bytes[0..bytes.len].ptr, bytes.len, 0));
    if (result != .SUCCESS) return SocketError.WriteError;
    return @as(usize, @intCast(result));
}

const GlobalState = @import("GlobalState.zig");
const c = std.c;
const posix = std.posix;
const std = @import("std");
const ArrayList = @import("ArrayList.zig");
const socket = @import("socket.zig");
const SocketError = socket.SocketError;

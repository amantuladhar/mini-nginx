fd: i32,
cursor: usize = 0,
exhausted: bool = false,
buffer: *ArrayList,

pub fn readUntil(self: *@This(), delimiter: u8) []u8 {
    if (self.readUntilWithinBuffer(delimiter)) |slice| return slice;

    var chunk: [100]u8 = undefined;
    while (!self.exhausted) {
        const read_count = utils.readFromSocket(self.fd, &chunk);
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

pub fn readExact(self: *@This(), count: u16) []u8 {
    if (self.readExactWithinBuffer(count)) |slice| return slice;

    var chunk: [100]u8 = undefined;
    while (!self.exhausted) {
        const read_count = utils.readFromSocket(self.fd, &chunk);
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

const std = @import("std");
const ArrayList = @import("ArrayList.zig");
const utils = @import("utils.zig");

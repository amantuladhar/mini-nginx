items: []u8,
len: usize,
capacity: usize,
allocator: Allocator,

const Self = @This();

pub fn init(allocator: Allocator) Self {
    return .{
        .items = &.{},
        .len = 0,
        .capacity = 0,
        .allocator = allocator,
    };
}

pub fn deinit(self: *@This()) void {
    if (self.items.len > 0) {
        self.allocator.free(self.items);
    }
}

pub fn append(self: *@This(), byte: u8) void {
    self.resizeIfNeeded();
    self.items[self.len] = byte;
    self.len += 1;
}

pub fn appendAll(self: *@This(), bytes: []u8) void {
    for (bytes) |it| self.append(it);
}

fn resizeIfNeeded(self: *@This()) void {
    if (self.len < self.capacity) {
        return;
    }
    self.capacity = @max(8, self.capacity) * 2;
    self.items = self.allocator.realloc(self.items, self.capacity) catch unreachable;
}
const std = @import("std");
const Allocator = std.mem.Allocator;

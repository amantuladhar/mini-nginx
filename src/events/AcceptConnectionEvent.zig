server_fd: usize,
event_data: *EventData,
allocator: Allocator,

const Self = @This();
const EventData = EventLoop.EventData;

pub fn init(allocator: Allocator, server_fd: usize) *Self {
    const self = allocator.create(Self) catch unreachable;
    const event_data = allocator.create(EventData) catch unreachable;

    self.* = .{ .server_fd = server_fd, .event_data = event_data, .allocator = allocator };
    event_data.* = .{ .ptr = self, .vtable = &.{ .callback = typeErasedCallback } };

    return self;
}

pub fn deinit(self: *@This()) void {
    self.allocator.destroy(self.event_data);
    self.allocator.destroy(self);
}

const AcceptConnectionEventError = error{} || SocketError || EventLoop.EventLoopError;

pub fn accept(self: *Self, event_loop: *EventLoop) AcceptConnectionEventError!void {
    std.log.debug("{d} AcceptConnectionEvent called", .{c.getpid()});
    const client_fd = try acceptClientConnection(self.server_fd);
    // @todo - allocator maybe should be args to function
    const proxy_work_event = ProxyWorkEvent.init(self.allocator, self.server_fd, client_fd);
    try event_loop.register(client_fd, .Read, proxy_work_event.event_data);
}

fn typeErasedCallback(context: *anyopaque, event_loop: *EventLoop) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.accept(event_loop) catch |err| {
        std.log.err("Error in AcceptConnectionEvent::accept: {any}", .{err});
    };
}

fn acceptClientConnection(server_fd: usize) SocketError!usize {
    var client_addr: posix.sockaddr.in = undefined;
    var client_addr_len: posix.socklen_t = @sizeOf(@TypeOf(client_addr));

    const client_fd = c.accept(@intCast(server_fd), @ptrCast(&client_addr), &client_addr_len);
    const result = posix.errno(client_fd);
    if (result != .SUCCESS) return error.AcceptFailed;
    std.log.info("{d} Connection from client accepted: {any}", .{ c.getpid(), client_addr });
    return @intCast(client_fd);
}

const std = @import("std");
const EventLoop = @import("../EventLoop.zig");
const GlobalState = @import("../GlobalState.zig");
const ProxyWorkEvent = @import("ProxyWorkEvent.zig");
const socket = @import("../socket.zig");
const SocketError = socket.SocketError;
const c = std.c;
const posix = std.posix;
const Allocator = std.mem.Allocator;

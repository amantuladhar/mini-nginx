server_fd: usize,
client_fd: usize,
proxy_fd: ?usize = null,
state: State = .WaitingClientRead,
event_data: *EventData,
http_request: ?HttpRequest = null,
http_response: ?HttpResponse = null,

allocator: Allocator,

const EventData = EventLoop.EventData;
const Self = @This();

pub fn init(allocator: Allocator, server_fd: usize, client_fd: usize) *Self {
    const self = allocator.create(Self) catch unreachable;
    const event_data = allocator.create(EventData) catch unreachable;

    self.* = .{
        .event_data = event_data,
        .allocator = allocator,
        .server_fd = server_fd,
        .client_fd = client_fd,
    };
    event_data.* = .{ .ptr = self, .vtable = &.{ .callback = typeErasedCallback } };

    return self;
}

pub fn deinit(self: *@This()) void {
    if (self.proxy_fd) |fd| {
        _ = c.close(@intCast(fd));
    }
    _ = c.close(@intCast(self.client_fd));
    if (self.http_request) |*req| {
        req.*.deinit();
    }
    if (self.http_response) |*res| {
        res.*.deinit();
    }
    self.allocator.destroy(self.event_data);
    self.allocator.destroy(self);
}

fn typeErasedCallback(context: *anyopaque, event_loop: *EventLoop) void {
    const self: *@This() = @ptrCast(@alignCast(context));
    self.work(event_loop) catch |err| {
        std.log.err("Error in ProxyWorkEvent::work: {any}", .{err});
    };
}

pub fn work(self: *Self, event_loop: *EventLoop) !void {
    std.log.debug("ProxyWorkEvent:: callback, {any}", .{self.state});
    errdefer self.deinit();

    switch (self.state) {
        .WaitingClientRead => {
            self.http_request = try HttpRequest.readFromSocket(self.allocator, self.client_fd);
            self.proxy_fd = try connectToBackendProxy(.{ 127, 0, 0, 1 }, 9999);
            try event_loop.registerWithOption(self.proxy_fd.?, .Write, self.event_data, .{ .oneshot = true });
            self.state = self.state.transition();
        },
        .WaitingProxyWrite => {
            _ = try socket.sendToSocket(self.proxy_fd.?, self.http_request.?.toBytes());
            try event_loop.registerWithOption(self.proxy_fd.?, .Read, self.event_data, .{ .oneshot = true });
            self.state = self.state.transition();
        },
        .WaitingProxyRead => {
            self.http_response = try HttpResponse.readFromSocket(self.allocator, self.proxy_fd.?);
            _ = try socket.sendToSocket(self.client_fd, self.http_response.?.toBytes());
            self.state = self.state.transition();
        },
        else => |x| {
            std.log.debug("Received {any}", .{x});
            self.state = .Error;
        },
    }
    if (self.state == .Complete or self.state == .Error) {
        std.log.debug("Work completed: -- {any}", .{self.state});
        self.deinit();
    }
}

fn connectToBackendProxy(addr: [4]u8, port: u16) !usize {
    const proxy_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var result = posix.errno(proxy_fd);
    if (result != .SUCCESS) return error.SocketInitFailed;

    const proxy_sock_addr_in: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .addr = @as(*align(1) const u32, @ptrCast(&addr)).*,
        .port = std.mem.nativeToBig(u16, port),
    };
    result = posix.errno(c.connect(proxy_fd, @ptrCast(&proxy_sock_addr_in), @sizeOf(@TypeOf(proxy_sock_addr_in))));
    // @todo - INPROGRESS needs to be handled
    if (result != .SUCCESS) return error.ProxyConnectFailed;

    return @intCast(proxy_fd);
}

const State = enum {
    WaitingClientRead,
    WaitingProxyWrite,
    WaitingProxyRead,
    Complete,
    Error,

    pub fn transition(self: State) State {
        return switch (self) {
            .WaitingClientRead => .WaitingProxyWrite,
            .WaitingProxyWrite => .WaitingProxyRead,
            .WaitingProxyRead => .Complete,
            else => .Error,
        };
    }
};

const std = @import("std");
const EventLoop = @import("../EventLoop.zig");
const GlobalState = @import("../GlobalState.zig");
const utils = @import("../utils.zig");
const ArrayList = @import("../ArrayList.zig");
const Http = @import("../Http.zig");
const socket = @import("../socket.zig");
const HttpRequest = Http.HttpRequest;
const HttpResponse = Http.HttpResponse;
const c = std.c;
const posix = std.posix;
const Allocator = std.mem.Allocator;

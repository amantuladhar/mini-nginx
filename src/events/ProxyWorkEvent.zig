server_fd: i32,
client_fd: i32,
proxy_fd: ?i32 = null,
state: State = .WaitingClientRead,
event_data: *EventData,
http_request: ?HttpRequest = null,
http_response: ?HttpResponse = null,

allocator: Allocator,

const EventData = EventLoop.EventData;
const Self = @This();

pub fn init(allocator: Allocator, server_fd: i32, client_fd: i32) *Self {
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
        _ = c.close(fd);
    }
    _ = c.close(self.client_fd);
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
    self.work(event_loop);
}

pub fn work(self: *Self, event_loop: *EventLoop) void {
    std.log.debug("ProxyWorkEvent:: callback, {any}", .{self.state});

    switch (self.state) {
        .WaitingClientRead => {
            self.http_request = HttpRequest.readFromSocket(self.allocator, self.client_fd);
            self.proxy_fd = connectToBackendProxy(.{ 127, 0, 0, 1 }, 9999);
            event_loop.registerWithOption(self.proxy_fd.?, .Write, self.event_data, .{ .oneshot = true });
            self.state = self.state.transition();
        },
        .WaitingProxyWrite => {
            utils.sendToSocket(self.proxy_fd.?, self.http_request.?.toBytes());
            event_loop.registerWithOption(self.proxy_fd.?, .Read, self.event_data, .{ .oneshot = true });
            self.state = self.state.transition();
        },
        .WaitingProxyRead => {
            self.http_response = HttpResponse.readFromSocket(self.allocator, self.proxy_fd.?);
            self.state = self.state.transition();
            utils.sendToSocket(self.client_fd, self.http_response.?.toBytes());
        },
        else => |x| {
            std.log.debug("Received {any}", .{x});
            self.state = .Error;
        },
    }
    if (self.state == .Complete or self.state == .Error) {
        self.deinit();
    }
}

fn connectToBackendProxy(addr: [4]u8, port: u16) i32 {
    const proxy_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var result = posix.errno(proxy_fd);
    if (result != .SUCCESS) {
        std.log.err("proxy socket call failed, {any}", .{result});
        GlobalState.requestShutdown();
    }
    const proxy_sock_addr_in: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .addr = @as(*align(1) const u32, @ptrCast(&addr)).*,
        .port = std.mem.nativeToBig(u16, port),
    };
    result = posix.errno(c.connect(proxy_fd, @ptrCast(&proxy_sock_addr_in), @sizeOf(@TypeOf(proxy_sock_addr_in))));
    if (result != .SUCCESS) {
        // @todo - INPROGRESS needs to be handled
        std.log.err("proxy connect call failed, {any}", .{result});
        GlobalState.requestShutdown();
    }
    return proxy_fd;
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
const HttpRequest = Http.HttpRequest;
const HttpResponse = Http.HttpResponse;
const c = std.c;
const posix = std.posix;
const Allocator = std.mem.Allocator;

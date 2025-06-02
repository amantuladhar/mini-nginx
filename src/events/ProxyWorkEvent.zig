server_fd: i32,
client_fd: i32,
proxy_fd: ?i32 = null,
state: State = .WaitingClientRead,
event_data: *EventData,
http_request: ?HttpRequest = null,
http_response: ?HttpResponse = null,
// @todo - proper http reader/writer
request_buffer: [4096]u8 = .{0} ** 4096,
request_buffer_read_count: isize = 0,
proxy_response_buffer: [4096]u8 = .{0} ** 4096,
proxy_response_buffer_read_count: isize = 0,
allocator: Allocator,

const EventData = EventLoop.EventData;
const Self = @This();

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

pub fn init(allocator: Allocator, server_fd: i32, client_fd: i32) *Self {
    const self = allocator.create(Self) catch unreachable;
    const event_data = allocator.create(EventData) catch unreachable;

    self.* = .{ .event_data = event_data, .allocator = allocator, .server_fd = server_fd, .client_fd = client_fd };
    event_data.* = .{ .ptr = self, .vtable = &.{ .callback = typeErasedCallback } };

    return self;
}

pub fn deinit(self: *@This()) void {
    if (self.proxy_fd) |fd| {
        _ = c.close(fd);
    }
    _ = c.close(self.client_fd);
    self.allocator.destroy(self.event_data);
    self.allocator.destroy(self);
}

fn typeErasedCallback(context: *anyopaque, event_loop: *EventLoop) void {
    const self: *@This() = @ptrCast(@alignCast(context));
    self.work(event_loop);
}

const SocketReader = struct {
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
};

const HttpStatusCode = enum(u16) {
    OK = 200,
    BadRequest = 400,
    Unauthorized = 401,
    Forbidden = 403,
    NotFound = 404,
    NotAllowed = 405,
    InternalServerError = 500,

    pub fn toString(self: Self) []const u8 {
        return switch (self) {
            .OK => "200 OK",
            .BadRequest => "400 Bad Request",
            .Unauthorized => "401 Unauthorized",
            .Forbidden => "403 Forbidden",
            .NotFound => "404 Not Found",
            .NotAllowed => "405 Method Not Allowed",
            .InternalServerError => "500 Internal Server Error",
        };
    }
};

const HttpResponse = struct {
    status_code: HttpStatusCode,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: Allocator,

    raw: ArrayList,

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        const my_fmt =
            \\--- Http Response ---
            \\ StatusCode: {any}
            \\ Headers Count: {d}
            \\ Body: <'{s}'>
        ;
        try writer.print(my_fmt, .{ self.status_code, self.headers.count(), self.body });
    }

    pub fn readFromSocket(allocator: Allocator, fd: i32) @This() {
        var buffer = ArrayList.init(allocator);
        var reader = SocketReader{ .fd = fd, .buffer = &buffer };

        const status_code = parseStatusCode(&reader);
        const headers = parseHeaders(allocator, &reader);
        const body: []u8 = if (headers.get("Content-Length")) |len| reader.readExact(std.fmt.parseInt(u16, len, 10) catch unreachable) else "";
        return .{
            .status_code = status_code,
            .headers = headers,
            .body = body,
            .allocator = allocator,
            .raw = buffer,
        };
    }

    fn parseHeaders(allocator: Allocator, reader: *SocketReader) std.StringHashMap([]const u8) {
        // @todo - implement your own hashmap
        var map = std.StringHashMap([]const u8).init(allocator);
        var line = reader.readUntil('\n');
        while (!std.mem.eql(u8, "\r\n", line)) {
            defer line = reader.readUntil('\n');

            var parts = std.mem.splitAny(u8, line, ":");
            const key = std.mem.trim(u8, parts.next().?, &std.ascii.whitespace);
            const value = std.mem.trim(u8, parts.next().?, &std.ascii.whitespace);
            map.put(key, value) catch unreachable;
        }
        return map;
    }

    fn parseStatusCode(reader: *SocketReader) HttpStatusCode {
        const line = reader.readUntil('\n');
        var parts = std.mem.splitAny(u8, line, " ");
        _ = parts.next().?;
        const status_code = parts.next().?;
        const enum_value = std.fmt.parseInt(u16, std.mem.trim(u8, status_code, &std.ascii.whitespace), 10) catch unreachable;
        std.log.debug("Parsed enum value: {d}", .{enum_value});
        return @enumFromInt(enum_value);
    }
};

const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: Allocator,

    raw: ArrayList,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const my_fmt =
            \\--- Http Request ---
            \\ Method: {s}, Path: {s}
            \\ Headers Count: {d}
            \\ Body: <'{s}'>
            \\ BufLen: <'{d}'>
        ;
        try writer.print(my_fmt, .{ self.method, self.path, self.headers.count(), self.body, self.raw.items.len });
    }

    pub fn readFromSocket(allocator: Allocator, fd: i32) HttpRequest {
        var buffer = ArrayList.init(allocator);
        var reader = SocketReader{ .fd = fd, .buffer = &buffer };

        const status_line = parseStatusLine(&reader);
        const headers = parseHeaders(allocator, &reader);
        const body: []u8 = if (headers.get("Content-Length")) |len| reader.readExact(std.fmt.parseInt(u16, len, 10) catch unreachable) else "";
        return .{
            .method = status_line.method,
            .path = status_line.path,
            .headers = headers,
            .body = body,
            .allocator = allocator,
            .raw = buffer,
        };
    }

    fn parseHeaders(allocator: Allocator, reader: *SocketReader) std.StringHashMap([]const u8) {
        // @todo - implement your own hashmap
        var map = std.StringHashMap([]const u8).init(allocator);
        var line = reader.readUntil('\n');
        while (!std.mem.eql(u8, "\r\n", line)) {
            defer line = reader.readUntil('\n');

            var parts = std.mem.splitAny(u8, line, ":");
            const key = std.mem.trim(u8, parts.next().?, &std.ascii.whitespace);
            const value = std.mem.trim(u8, parts.next().?, &std.ascii.whitespace);
            map.put(key, value) catch unreachable;
        }
        return map;
    }

    fn parseStatusLine(reader: *SocketReader) struct { method: []const u8, path: []const u8 } {
        const line = reader.readUntil('\n');
        var parts = std.mem.splitAny(u8, line, " ");
        const method = parts.next().?;
        const path = parts.next().?;
        return .{ .method = method, .path = path };
    }
};

pub fn work(self: *Self, event_loop: *EventLoop) void {
    std.log.debug("ProxyWorkEvent:: callback, {any}", .{self.state});

    state_selector: switch (self.state) {
        .WaitingClientRead => {
            self.http_request = HttpRequest.readFromSocket(self.allocator, self.client_fd);
            std.log.debug("{any}", .{self.http_request});

            // self.request_buffer_read_count = utils.readFromSocket(self.client_fd, &self.request_buffer);
            self.proxy_fd = connectToBackendProxy(.{ 127, 0, 0, 1 }, 9999);
            event_loop.registerWithOption(self.proxy_fd.?, .Write, self.event_data, .{ .oneshot = true });
            self.state = self.state.transition();
        },
        .WaitingProxyWrite => {
            if (self.http_request == null) {
                std.log.err("No HTTP request found, cannot proceed with proxying", .{});
                self.state = .Error;
                break :state_selector;
            }
            if (self.proxy_fd == null) {
                std.log.err("No proxy socket found, cannot proceed with proxying", .{});
                self.state = .Error;
                break :state_selector;
            }
            const buffer: []u8 = self.http_request.?.raw.items;
            utils.sendToSocket(self.proxy_fd.?, buffer[0..@intCast(buffer.len)]);
            event_loop.registerWithOption(self.proxy_fd.?, .Read, self.event_data, .{ .oneshot = true });
            self.state = self.state.transition();
        },
        .WaitingProxyRead => {
            if (self.proxy_fd == null) {
                std.log.err("No proxy socket found, cannot proceed with proxying", .{});
                self.state = .Error;
                break :state_selector;
            }
            self.http_response = HttpResponse.readFromSocket(self.allocator, self.proxy_fd.?);
            std.log.debug("{any}", .{self.http_response});
            // mark
            // self.proxy_response_buffer_read_count = utils.readFromSocket(self.proxy_fd.?, &self.proxy_response_buffer);
            self.state = self.state.transition();

            utils.sendToSocket(self.client_fd, self.proxy_response_buffer[0..@intCast(self.proxy_response_buffer_read_count)]);
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

const std = @import("std");
const EventLoop = @import("../EventLoop.zig");
const GlobalState = @import("../GlobalState.zig");
const utils = @import("../utils.zig");
const ArrayList = @import("../ArrayList.zig");
const c = std.c;
const posix = std.posix;
const Allocator = std.mem.Allocator;

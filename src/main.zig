pub fn main() !void {
    const gpa, const deinit = getAllocator();
    defer _ = if (deinit) debug_allocator.deinit();

    const cli_args: CliArgs = try .parse();
    var loop: EventLoop = .init();

    const server: [4]u8 = .{0} ** 4;
    const server_port: u16 = cli_args.port;
    const server_fd = setupMasterSocketListener(server, server_port);
    defer _ = c.close(server_fd);

    const accept_event = AcceptConnectionEvent.init(gpa, server_fd);
    loop.register(server_fd, .Read, accept_event.event_data);

    loop.run();

    // const client_fd = acceptClientConnection(server_fd);
    // defer _ = c.close(client_fd);

    // const BUFFER_SIZE = 4096;
    // var buffer: [BUFFER_SIZE]u8 = .{0} ** BUFFER_SIZE;
    // const read_count = readFromSocket(client_fd, &buffer);

    // // proxy if proxy port is set
    // const proxy_resp = blk: {
    //     if (cli_args.proxy_port) |proxy_port| {
    //         const proxy_addr: [4]u8 = .{ 127, 0, 0, 1 };
    //         const proxy_fd = connectToBackendProxy(proxy_addr, proxy_port);
    //         defer _ = c.close(proxy_fd);
    //         sendToSocket(proxy_fd, buffer[0..@intCast(read_count)]);

    //         var proxy_buffer: [BUFFER_SIZE]u8 = .{0} ** BUFFER_SIZE;
    //         const proxy_read_count = readFromSocket(proxy_fd, &proxy_buffer);
    //         break :blk proxy_buffer[0..@intCast(proxy_read_count)];
    //     }
    //     break :blk "";
    // };

    // sendToSocket(client_fd, proxy_resp);
}
const AcceptConnectionEvent = struct {
    const EventData = EventLoop.EventData;

    server_fd: i32,
    event_data: *EventData,
    allocator: Allocator,

    pub fn init(allocator: Allocator, server_fd: i32) *AcceptConnectionEvent {
        const self = allocator.create(AcceptConnectionEvent) catch unreachable;
        const event_data = allocator.create(EventData) catch unreachable;

        self.* = .{ .server_fd = server_fd, .event_data = event_data, .allocator = allocator };

        event_data.* = .{
            .ptr = self,
            .vtable = &.{ .callback = AcceptConnectionEvent.callback },
        };

        return self;
    }
    pub fn deinit(self: *@This()) void {
        self.allocator.destroy(self.event_data);
        self.destroy(self);
    }

    pub fn callback(context: *anyopaque, event_loop: *EventLoop) void {
        const self: *AcceptConnectionEvent = @ptrCast(@alignCast(context));
        _ = self;
        _ = event_loop;
        std.log.debug("AcceptConnectionEvent called", .{});
    }
};

const EventLoop = struct {
    queue_fd: i32,

    const Event = switch (builtin.os.tag) {
        .macos => c.kevent64_s,
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
    };

    const Interest = enum(comptime_int) {
        Read = std.c.EVFILT.READ,
    };

    const EventData = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        const VTable = struct {
            callback: *const fn (self: *anyopaque, event_loop: *EventLoop) void,
        };

        pub fn callback(self: *EventData, event_loop: *EventLoop) void {
            self.vtable.callback(self.ptr, event_loop);
        }
    };

    pub fn init() EventLoop {
        const queue_fd = c.kqueue();
        if (posix.errno(queue_fd) != .SUCCESS) {
            std.log.err("kqueue call failed: {any}", .{posix.errno(queue_fd)});
            std.process.exit(1);
        }
        return .{ .queue_fd = queue_fd };
    }

    pub fn deinit(self: *EventLoop) void {
        _ = c.close(self.queue_fd);
    }

    pub fn run(self: *EventLoop) void {
        std.log.info("running event loop...", .{});
        var events: [10]Event = undefined;
        while (true) {
            const nev = poll(self.queue_fd, &events);
            std.log.info("received {d} events", .{nev});
            for (events[0..@intCast(nev)]) |event| {
                const edata = parseEventData(&event);
                edata.callback(self);
            }
        }
    }

    fn parseEventData(event: *const Event) *EventData {
        const edata: *EventData = switch (builtin.os.tag) {
            .macos => @ptrFromInt(event.udata),
            else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
        };
        return edata;
    }

    fn poll(queuefd: i32, events: []Event) i32 {
        var changelists: [0]Event = undefined;
        const result = switch (builtin.os.tag) {
            .macos => c.kevent64(
                queuefd,
                changelists[0..0].ptr,
                0,
                events[0..events.len].ptr,
                @intCast(events.len),
                0,
                null,
            ),
            else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
        };
        if (posix.errno(result) != .SUCCESS) {
            std.log.err("kevent call failed: {any}", .{posix.errno(result)});
            std.process.exit(1);
        }
        return result;
    }

    pub fn register(self: *const EventLoop, where: i32, what: Interest, event_data: *EventData) void {
        const data = @intFromPtr(event_data);
        const changelist: [1]Event = [_]Event{.{
            .ident = @intCast(where),
            .filter = @intFromEnum(what),
            .flags = std.c.EV.ADD | std.c.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = data,
            .ext = .{0} ** 2,
        }};
        var events: [0]Event = undefined;
        const result = c.kevent64(self.queue_fd, changelist[0..1].ptr, 1, events[0..0], 0, 0, null);
        if (posix.errno(result) != .SUCCESS) {
            std.log.err("kevent call failed: {any}", .{posix.errno(result)});
            std.process.exit(1);
        }
    }
};

fn connectToBackendProxy(addr: [4]u8, port: u16) i32 {
    const proxy_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var result = posix.errno(proxy_fd);
    if (result != .SUCCESS) {
        std.log.err("proxy socket call failed, {any}", .{result});
        std.process.exit(1);
    }
    const proxy_sock_addr_in: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .addr = @as(*align(1) const u32, @ptrCast(&addr)).*,
        .port = std.mem.nativeToBig(u16, port),
    };
    result = posix.errno(c.connect(proxy_fd, @ptrCast(&proxy_sock_addr_in), @sizeOf(@TypeOf(proxy_sock_addr_in))));
    if (result != .SUCCESS) {
        // INPROGRESS needs to be handled
        std.log.err("proxy connect call failed, {any}", .{result});
        std.process.exit(1);
    }
    return proxy_fd;
}

fn sendToSocket(socket: i32, bytes: []const u8) void {
    // var result = posix.errno(c.send(socket, buffer[0..@intCast(read_count)].ptr, @intCast(read_count), 0));
    const result = posix.errno(c.send(socket, bytes[0..bytes.len].ptr, bytes.len, 0));
    if (result != .SUCCESS) {
        std.log.err("proxy send call failed, {any}", .{result});
        std.process.exit(1);
    }
}

fn readFromSocket(socket: i32, buffer: []u8) isize {
    const read_count = c.read(socket, buffer[0..buffer.len].ptr, buffer.len);
    const result = posix.errno(read_count);
    if (result != .SUCCESS) {
        std.log.err("call to read failed: {any}", .{result});
        std.process.exit(1);
    }
    return read_count;
}

fn acceptClientConnection(server_fd: i32) i32 {
    var client_addr: posix.sockaddr.in = undefined;
    var client_addr_len: posix.socklen_t = @sizeOf(@TypeOf(client_addr));

    const client_fd = c.accept(server_fd, @ptrCast(&client_addr), &client_addr_len);

    const result = posix.errno(client_fd);
    if (result != .SUCCESS) {
        std.log.err("call to accept failed: {any}", .{result});
        std.process.exit(1);
    }
    std.log.info("Connection from client accepted: {any}", .{client_addr});
    return client_fd;
}

fn setupMasterSocketListener(server: [4]u8, port: u16) i32 {
    const server_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var result = posix.errno(server_fd);
    if (result != .SUCCESS) {
        std.log.err("Call to socket failed: {any}", .{result});
        std.process.exit(1);
    }

    result = posix.errno(c.setsockopt(server_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &@as(u32, 1), @sizeOf(u32)));
    if (result != .SUCCESS) {
        std.log.err("call to setsockopt failed: {any}", .{result});
        std.process.exit(1);
    }
    const sock_addr_in: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        // inet_addr or inet_pton can be used but zig version of struct doesn't have this field. Hmm...
        .addr = @as(*align(1) const u32, @ptrCast(&server)).*,
        .port = std.mem.nativeToBig(u16, port),
    };
    result = posix.errno(c.bind(server_fd, @ptrCast(&sock_addr_in), @sizeOf(@TypeOf(sock_addr_in))));
    if (result != .SUCCESS) {
        std.log.err("call to bind failed: {any}", .{result});
        std.process.exit(1);
    }

    result = posix.errno(c.listen(server_fd, 1));
    if (result != .SUCCESS) {
        std.log.err("call to listen failed: {any}", .{result});
        std.process.exit(1);
    }

    const existing_flag = c.fcntl(server_fd, posix.F.GETFL, @as(u32, 0));
    result = posix.errno(existing_flag);
    if (result != .SUCCESS) {
        std.log.err("call to fcntl failed: {any}", .{result});
        std.process.exit(1);
    }

    result = posix.errno(c.fcntl(server_fd, posix.F.SETFL, @as(usize, @intCast(existing_flag)) | posix.SOCK.NONBLOCK));
    if (result != .SUCCESS) {
        std.log.err("call to fcntl failed: {any}", .{result});
        std.process.exit(1);
    }

    std.log.info("Waiting for client connection:\nport: {d}", .{port});

    return server_fd;
}

const CliArgs = struct {
    port: u16 = 8080,
    msg: []const u8 = "[server 1]",
    proxy_port: ?u16 = null,

    pub fn parse() !CliArgs {
        var args = std.process.args();
        _ = args.next();

        var cli_args: CliArgs = .{};

        while (args.next()) |arg| {
            if (std.mem.eql(u8, "--port", arg)) {
                const port = args.next() orelse unreachable;
                cli_args.port = try std.fmt.parseInt(u16, port, 10);
                continue;
            }
            if (std.mem.eql(u8, "--msg", arg)) {
                const msg = args.next() orelse unreachable;
                cli_args.msg = msg;
                continue;
            }
            if (std.mem.eql(u8, "--proxy-port", arg)) {
                const proxy_port = args.next() orelse unreachable;
                cli_args.proxy_port = try std.fmt.parseInt(u16, proxy_port, 10);
                continue;
            }
        }
        return cli_args;
    }
};

fn getAllocator() struct { Allocator, bool } {
    return switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ debug_allocator.allocator(), true },
    };
}

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const native_os = builtin.os.tag;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

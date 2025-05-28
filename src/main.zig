pub fn main() !void {
    const gpa, const deinit = getAllocator();
    defer _ = if (deinit) debug_allocator.deinit();

    const master_socket_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var result = posix.errno(master_socket_fd);
    if (result != .SUCCESS) {
        log.err("socket creation failed: {any}", .{result});
        std.process.exit(1);
    }
    defer _ = c.close(master_socket_fd);
    const opt: u32 = 1;

    result = posix.errno(c.setsockopt(master_socket_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &opt, @sizeOf(u32)));
    if (result != .SUCCESS) {
        log.err("set sock opt failed {any}", .{result});
        std.process.exit(1);
    }

    const addr: [4]u8 = .{ 0, 0, 0, 0 };
    const port = 8080;
    const sock_addr: posix.sockaddr.in = .{
        .family = posix.AF.INET, // ipv4
        .addr = @as(*align(1) const u32, @ptrCast(&addr)).*,
        .port = std.mem.nativeToBig(u16, port),
    };
    result = posix.errno(c.bind(master_socket_fd, @ptrCast(&sock_addr), @sizeOf(posix.sockaddr.in)));
    if (result != .SUCCESS) {
        log.err("bind failed: {d}", .{result});
        std.process.exit(1);
    }

    result = posix.errno(c.listen(master_socket_fd, 3));
    if (result != .SUCCESS) {
        log.err("listen failed: {any}", .{result});
        std.process.exit(1);
    }

    const existing_flags = c.fcntl(master_socket_fd, posix.F.GETFL, @as(c_int, 0));
    result = posix.errno(c.fcntl(master_socket_fd, posix.F.SETFL, existing_flags | posix.SOCK.NONBLOCK));

    if (result != .SUCCESS) {
        log.err("fcntl failed: {any}", .{result});
        std.process.exit(1);
    }

    var client_addr: posix.sockaddr.in = .{ .family = posix.AF.INET, .addr = 0, .port = 0 };
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

    const client_socket_fd = c.accept(master_socket_fd, @ptrCast(&client_addr), &addr_len);
    result = posix.errno(client_socket_fd);
    if (result != .SUCCESS) {
        log.err("accept failed: {any}", .{result});
        std.process.exit(1);
    }
    log.info("Connection accepted: {any}", .{client_addr});

    const BUFFER_SIZE: usize = 1024;
    var buffer: [BUFFER_SIZE]u8 = [_]u8{0} ** BUFFER_SIZE;

    const read_count = c.read(client_socket_fd, buffer[0..BUFFER_SIZE].ptr, BUFFER_SIZE);
    result = posix.errno(read_count);
    if (result != .SUCCESS) {
        log.err("read failed: {any}", .{result});
        std.process.exit(1);
    }
    defer _ = c.close(client_socket_fd);

    log.info("Read: {s}", .{buffer[0..@intCast(read_count)]});

    const reply = try std.fmt.allocPrint(gpa, "Reply to {s}", .{buffer[0..@intCast(read_count)]});
    defer gpa.free(reply);

    const bytes_send = c.send(client_socket_fd, reply.ptr, reply.len, 0);
    result = posix.errno(bytes_send);
    if (result != .SUCCESS) {
        log.err("send failed: {any}", .{result});
        std.process.exit(1);
    }
}

const EventLoop = struct {
    queue_fd: i32,
    listeners: Listeners,
    gpa: std.mem.Allocator,

    const Self = @This();

    const Listeners = std.AutoHashMap(i32, EventData(*anyopaque));

    const EventLoopError = error{FailedToCreateQueue};

    const Interest = enum(comptime_int) {
        Read = switch (builtin.os.tag) {
            .macos => c.EVFILT.READ,
            .linux => std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET,
            else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
        },
    };

    const Event = switch (builtin.os.tag) {
        .macos => posix.Kevent,
        .linux => std.os.linux.epoll_event,
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
    };

    pub fn EventData(comptime T: type) type {
        return struct {
            ctx: *T,
            callback: *const fn (*@This()) anyerror!void,
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator, data: T) *@This() {
                const ctx = allocator.create(T) catch unreachable;
                errdefer allocator.destroy(ctx);
                ctx.* = data;

                const self = allocator.create(@This()) catch unreachable;
                const callback = @field(T, "callback");
                self.* = .{
                    .allocator = allocator,
                    .ctx = ctx,
                    .callback = callback,
                };
                return self;
            }

            pub fn deinit(self: *@This()) void {
                if (@hasDecl(T, "deinit")) {
                    const ctxDeinit = @field(T, "deinit");
                    ctxDeinit(self.ctx);
                }
                self.allocator.destroy(self);
            }
        };
    }

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .queue_fd = createQueue(),
            .listeners = Listeners.init(gpa),
        };
    }
    pub fn deinit(s: *Self) void {
        s.listeners.deinit();
        c.close(s.queue_fd);
    }

    pub fn register(self: *Self, source_fd: i32, interest: Interest, comptime T: type, event_data: *EventData(T)) !void {
        self.registerEvent(source_fd, interest, @intFromPtr(event_data));
        try self.listeners.append(source_fd);
    }
    pub fn unregister(self: *Self, fd: i32, interest: Interest) !void {
        try unregisterEvent(self.eventfd, fd, interest);
        var edata = self.registered_fds.fetchRemove(fd);
        edata.?.value.deinit();
    }

    fn unregisterEvent(self: *Self, source_fd: i32, interest: Interest) !void {
        switch (builtin.os.tag) {
            .macos => {
                const changelist: []const Event = &[_]Event{.{
                    .ident = @intCast(source_fd),
                    .filter = @intFromEnum(interest),
                    .flags = std.c.EV.DELETE | std.c.EV.DISABLE,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                }};
                var events: [0]Event = undefined;
                _ = try posix.kevent(self.queue_fd, changelist, &events, null);
            },
            .linux => {
                _ = std.os.linux.epoll_ctl(
                    self.queue_fd,
                    std.os.linux.EPOLL.CTL_DEL,
                    @intCast(source_fd),
                    null,
                );
            },
            else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
        }
    }

    fn registerEvent(self: *Self, fd: i32, interest: Interest, data: usize) !void {
        return switch (builtin.os.tag) {
            .macos => {
                const changelist: []const Event = &[_]Event{.{
                    .ident = @intCast(fd),
                    .filter = @intFromEnum(interest),
                    .flags = std.c.EV.ADD | std.c.EV.ENABLE,
                    .fflags = 0,
                    .data = 0,
                    .udata = data,
                }};
                var events: [0]Event = undefined;
                _ = try posix.kevent(self.queue_fd, changelist, &events, null);
            },
            .linux => {
                var event = Event{
                    .events = @intFromEnum(interest),
                    .data = .{ .ptr = data },
                };
                _ = std.os.linux.epoll_ctl(
                    self.queue_fd,
                    std.os.linux.EPOLL.CTL_ADD,
                    @intCast(fd),
                    &event,
                );
            },
            else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
        };
    }

    fn getEventData(event: *const Event) *EventData(anyopaque) {
        const edata: *EventData(anyopaque) = switch (builtin.os.tag) {
            .macos => @ptrFromInt(event.udata),
            .linux => @ptrFromInt(event.data.ptr),
            else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
        };
        return edata;
    }

    fn createQueue() EventLoopError!i32 {
        const queue_fd = switch (builtin.os.tag) {
            .macos => return c.kqueue(),
            .linux => return c.epoll_create1(0),
            else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
        };
        switch (posix.errno(queue_fd)) {
            .SUCCESS => return queue_fd,
            else => |err| {
                log.err("Failed to create event queue: {any}", .{err});
                // @todo - Add proper error types
                return error.FailedToCreateQueue;
            },
        }
    }
};

pub fn getAllocator() struct { Allocator, bool } {
    return switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
}

const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const Allocator = std.mem.Allocator;
const c = std.c;
const posix = std.posix;
const native_os = builtin.os.tag;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

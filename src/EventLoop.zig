queue_fd: i32,

const Self = @This();

const Event = switch (builtin.os.tag) {
    .macos => c.kevent64_s,
    .linux => std.os.linux.epoll_event,
    else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
};

const Interest = enum(comptime_int) {
    Read = switch (builtin.os.tag) {
        .macos => std.c.EVFILT.READ,
        .linux => std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET,
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
    },
    Write = switch (builtin.os.tag) {
        .macos => std.c.EVFILT.WRITE,
        .linux => std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ET,
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
    },
};

const Options = struct {
    oneshot: bool = false,
};

pub const EventData = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        callback: *const fn (self: *anyopaque, event_loop: *Self) void,
    };

    pub fn callback(self: *EventData, event_loop: *Self) void {
        self.vtable.callback(self.ptr, event_loop);
    }
};

pub const EventLoopError = error{
    InitFailed,
    RegisterFailed,
};

pub fn init() EventLoopError!Self {
    const queue_fd = switch (builtin.os.tag) {
        .macos => c.kqueue(),
        .linux => c.epoll_create1(0),
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
    };

    if (posix.errno(queue_fd) != .SUCCESS) return error.InitFailed;
    return .{ .queue_fd = queue_fd };
}

pub fn deinit(self: *Self) void {
    _ = c.close(self.queue_fd);
}

pub fn run(self: *Self) void {
    std.log.info("running event loop...", .{});
    var events: [10]Event = undefined;
    while (!GlobalState.isShutdownRequested()) {
        std.log.debug("{d} -- polling", .{c.getpid()});
        const nev = poll(self.queue_fd, &events);
        const result = posix.errno(nev);
        if (result != .SUCCESS) {
            std.log.err("kevent call failed: {any}", .{posix.errno(nev)});
            continue;
        }
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
        .linux => @ptrFromInt(event.data.ptr),
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
        .linux => c.epoll_wait(
            queuefd,
            events[0..events.len].ptr,
            @intCast(events.len),
            -1,
        ),
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
    };
    return result;
}

pub fn register(self: *const Self, where: usize, what: Interest, event_data: *EventData) EventLoopError!void {
    try self.registerWithOption(where, what, event_data, .{});
}
pub fn unregister(self: *const Self, where: usize, what: Interest) EventLoopError!void {
    switch (builtin.os.tag) {
        .macos => {
            const changelist: []const Event = &[_]Event{.{
                .ident = @intCast(where),
                .filter = @intFromEnum(what),
                .flags = std.c.EV.DELETE | std.c.EV.DISABLE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            }};
            var events: [0]Event = undefined;
            _ = try posix.kevent(self.queue_fd, changelist, &events, null);
        },
        .linux => {
            _ = std.os.linux.epoll_ctl(self.queue_fd, std.os.linux.EPOLL.CTL_DEL, @intCast(where), null);
        },
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
    }
}

pub fn registerWithOption(self: *const Self, where: usize, what: Interest, event_data: *EventData, options: Options) EventLoopError!void {
    const data = @intFromPtr(event_data);
    switch (builtin.os.tag) {
        .macos => {
            var flags: u16 = std.c.EV.ADD;
            flags |= if (options.oneshot) std.c.EV.ONESHOT else std.c.EV.ENABLE;
            const changelist: [1]Event = [_]Event{.{
                .ident = @intCast(where),
                .filter = @intFromEnum(what),
                .flags = flags,
                .fflags = 0,
                .data = 0,
                .udata = data,
                .ext = .{0} ** 2,
            }};
            var events: [0]Event = undefined;
            const result = c.kevent64(
                self.queue_fd,
                changelist[0..1].ptr,
                1,
                events[0..0],
                0,
                0,
                null,
            );
            if (posix.errno(result) != .SUCCESS) {
                std.log.err("kevent call failed: {any}", .{posix.errno(result)});
                return error.RegisterFailed;
            }
        },
        .linux => {
            var event = Event{
                .events = @intFromEnum(what) | if (options.oneshot) std.os.linux.EPOLL.ONESHOT else 0,
                .data = .{ .ptr = data },
            };
            var result = c.epoll_ctl(self.queue_fd, std.os.linux.EPOLL.CTL_ADD, @intCast(where), &event);
            var errno = posix.errno(result);

            if (errno != .SUCCESS and errno == .EXIST) {
                result = c.epoll_ctl(self.queue_fd, std.os.linux.EPOLL.CTL_MOD, @intCast(where), &event);
                errno = posix.errno(result);
            }
            if (errno != .SUCCESS) {
                std.log.err("epoll_ctl call failed: {any}", .{posix.errno(result)});
                return error.RegisterFailed;
            }
        },
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
    }
}
const std = @import("std");
const builtin = @import("builtin");
const GlobalState = @import("GlobalState.zig");
const c = std.c;
const posix = std.posix;

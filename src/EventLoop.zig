queue_fd: i32,

const Self = @This();

const Event = switch (builtin.os.tag) {
    .macos => c.kevent64_s,
    else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
};

const Interest = enum(comptime_int) {
    Read = std.c.EVFILT.READ,
    Write = std.c.EVFILT.WRITE,
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

pub fn init() Self {
    const queue_fd = c.kqueue();
    if (posix.errno(queue_fd) != .SUCCESS) {
        std.log.err("kqueue call failed: {any}", .{posix.errno(queue_fd)});
        GlobalState.requestShutdown();
    }
    return .{ .queue_fd = queue_fd };
}

pub fn deinit(self: *Self) void {
    _ = c.close(self.queue_fd);
}

pub fn run(self: *Self) void {
    std.log.info("running event loop...", .{});
    var events: [10]Event = undefined;
    while (!GlobalState.isShutdownRequested()) {
        const nev = poll(self.queue_fd, &events);
        const result = posix.errno(nev);
        if (result != .SUCCESS) {
            if (result != .INTR) {
                std.log.err("kevent call failed: {any}", .{posix.errno(nev)});
                GlobalState.requestShutdown();
            }
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
    return result;
}
pub fn register(self: *const Self, where: i32, what: Interest, event_data: *EventData) void {
    self.registerWithOption(where, what, event_data, .{});
}

pub fn registerWithOption(self: *const Self, where: i32, what: Interest, event_data: *EventData, options: Options) void {
    const data = @intFromPtr(event_data);
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
    const result = c.kevent64(self.queue_fd, changelist[0..1].ptr, 1, events[0..0], 0, 0, null);
    if (posix.errno(result) != .SUCCESS) {
        std.log.err("kevent call failed: {any}", .{posix.errno(result)});
        GlobalState.requestShutdown();
    }
}
const std = @import("std");
const builtin = @import("builtin");
const GlobalState = @import("GlobalState.zig");
const c = std.c;
const posix = std.posix;

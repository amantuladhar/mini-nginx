pub fn main() !void {
    const allocator, const deinit = getAllocator();
    defer _ = if (deinit) debug_allocator.deinit();
    std.log.info("Parent is alive!! {d}", .{c.getpid()});

    setupGracefulShutdown();

    const cli_args = try CliArgs.parse();

    const server: [4]u8 = .{0} ** 4;
    const server_port: u16 = cli_args.port;
    const server_fd = setupMasterSocketListener(server, server_port);
    defer _ = c.close(server_fd);

    for (0..5) |it| {
        _ = it;
        const pid = c.fork();
        switch (pid) {
            -1 => {
                std.log.err("Fork failed: {any}", .{posix.errno(pid)});
            },
            0 => {
                std.log.info("I(child) am alive!!! - {d}", .{c.getpid()});
                GlobalState.setProcessType(.Child);

                var child_loop = EventLoop.init();
                defer child_loop.deinit();

                const accept_event = AcceptConnectionEvent.init(allocator, server_fd);
                defer accept_event.deinit();

                child_loop.register(server_fd, .Read, accept_event.event_data);
                child_loop.run();
            },
            else => {
                std.log.info("child process started with PID: {d}", .{pid});
            },
        }
    }
    switch (GlobalState.processType()) {
        .Parent => {
            _ = c.waitpid(-1, null, 0);
            std.log.info("All child process has been stopped", .{});
        },
        .Child => {
            std.log.info("Child process exited: {d}", .{c.getpid()});
        },
    }
}

const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
};

fn setupMasterSocketListener(server: [4]u8, port: u16) i32 {
    const server_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var result = posix.errno(server_fd);
    if (result != .SUCCESS) {
        std.log.err("Call to socket failed: {any}", .{result});
        GlobalState.requestShutdown();
    }

    result = posix.errno(c.setsockopt(server_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &@as(u32, 1), @sizeOf(u32)));
    if (result != .SUCCESS) {
        std.log.err("call to setsockopt failed: {any}", .{result});
        GlobalState.requestShutdown();
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
        GlobalState.requestShutdown();
    }

    result = posix.errno(c.listen(server_fd, 1));
    if (result != .SUCCESS) {
        std.log.err("call to listen failed: {any}", .{result});
        GlobalState.requestShutdown();
    }

    const existing_flag = c.fcntl(server_fd, posix.F.GETFL, @as(u32, 0));
    result = posix.errno(existing_flag);
    if (result != .SUCCESS) {
        std.log.err("call to fcntl failed: {any}", .{result});
        GlobalState.requestShutdown();
    }

    result = posix.errno(c.fcntl(server_fd, posix.F.SETFL, @as(usize, @intCast(existing_flag)) | posix.SOCK.NONBLOCK));
    if (result != .SUCCESS) {
        std.log.err("call to fcntl failed: {any}", .{result});
        GlobalState.requestShutdown();
    }

    std.log.info("Waiting for client connection:\nport: {d}", .{port});

    return server_fd;
}

fn getAllocator() struct { Allocator, bool } {
    return switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ debug_allocator.allocator(), true },
    };
}

fn gracefulShutdownHandler(sig: i32, info: *const posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    _ = info;
    _ = ctx_ptr;
    std.log.info("Received signal {d}, shutting down gracefully...", .{sig});
    GlobalState.requestShutdown();
}

fn setupGracefulShutdown() void {
    var act = posix.Sigaction{
        .handler = .{ .sigaction = gracefulShutdownHandler },
        .mask = posix.empty_sigset,
        .flags = (posix.SA.SIGINFO | posix.SA.RESTART | posix.SA.RESETHAND),
    };
    var result = c.sigaction(c.SIG.TERM, &act, null);
    if (posix.errno(result) != .SUCCESS) {
        std.log.err("sigaction call failed term: {any}", .{posix.errno(result)});
        GlobalState.requestShutdown();
    }
    result = c.sigaction(c.SIG.INT, &act, null);
    if (posix.errno(result) != .SUCCESS) {
        std.log.err("sigaction call failed int: {any}", .{posix.errno(result)});
        GlobalState.requestShutdown();
    }
}

const std = @import("std");
const builtin = @import("builtin");
const GlobalState = @import("GlobalState.zig");
const CliArgs = @import("CliArgs.zig");
const EventLoop = @import("EventLoop.zig");
const AcceptConnectionEvent = @import("AcceptConnectionEvent.zig");
const c = std.c;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const native_os = builtin.os.tag;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const allocator, const deinit = getAllocator();
    defer _ = if (deinit) debug_allocator.deinit();

    std.log.info("Parent is alive!! {d}", .{c.getpid()});

    setupGracefulShutdown();

    const cli_args = try CliArgs.parse();

    const server: [4]u8 = .{0} ** 4;
    const server_port: u16 = cli_args.port;
    const server_fd = try setupMasterSocketListener(server, server_port);
    defer _ = c.close(@intCast(server_fd));

    if (cli_args.num_of_workers == 0) {
        try workerLoop(allocator, server_fd);
        return;
    }

    for (0..cli_args.num_of_workers) |it| {
        _ = it;
        const pid = c.fork();
        // @todo CPU Affinity
        switch (pid) {
            -1 => std.log.err("Fork failed: {any}", .{posix.errno(pid)}),
            0 => {
                std.log.info("I(child) am alive!!! - {d}", .{c.getpid()});
                try workerLoop(allocator, server_fd);
                break; // child process doesn't need to run another child process
            },
            else => |cpid| {
                std.log.info("child process started with PID: {d}", .{cpid});
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
fn workerLoop(allocator: Allocator, server_fd: usize) !void {
    GlobalState.setProcessType(.Child);

    var loop = try EventLoop.init();
    defer loop.deinit();

    const accept_event = AcceptConnectionEvent.init(allocator, server_fd);
    defer accept_event.deinit();

    try loop.register(server_fd, .Read, accept_event.event_data);
    loop.run();
    std.log.debug("{d} Worker loop finished", .{c.getpid()});
}

fn setupMasterSocketListener(server: [4]u8, port: u16) !usize {
    const server_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var result = posix.errno(server_fd);
    if (result != .SUCCESS) return error.SocketInitFailed;

    try setNonblocking(@intCast(server_fd));

    result = posix.errno(c.setsockopt(server_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &@as(u32, 1), @sizeOf(u32)));
    if (result != .SUCCESS) return error.SetSocketOptionFailed;
    const sock_addr_in: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        // inet_addr or inet_pton can be used but zig version of struct doesn't have this field. Hmm...
        .addr = @as(*align(1) const u32, @ptrCast(&server)).*,
        .port = std.mem.nativeToBig(u16, port),
    };

    result = posix.errno(c.bind(server_fd, @ptrCast(&sock_addr_in), @sizeOf(@TypeOf(sock_addr_in))));
    if (result != .SUCCESS) return error.BindFailed;

    result = posix.errno(c.listen(server_fd, 1));
    if (result != .SUCCESS) return error.ListenFailed;
    std.log.info("Waiting for client connection:\nport: {d}", .{port});
    return @intCast(server_fd);
}

// This way to make socket non blocking is not working via zig
pub fn setNonblocking(fd: usize) SocketError!void {
    const existing_flag = c.fcntl(@intCast(fd), posix.F.GETFL, @as(u32, 0));
    var result = posix.errno(existing_flag);
    if (result != .SUCCESS) return error.GetFlagFailed;

    const O_NONBLOCK_VALUE: u32 = switch (builtin.os.tag) {
        // .macos => 0x4,
        .macos => @bitCast(std.c.O{ .NONBLOCK = true }),
        .linux => @bitCast(std.c.O{ .NONBLOCK = true }),
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
    };
    result = posix.errno(c.fcntl(@intCast(fd), posix.F.SETFL, @as(usize, @intCast(existing_flag)) | O_NONBLOCK_VALUE));
    if (result != .SUCCESS) return error.SetFlagFailed;
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
        std.log.err("{d}: sigaction call failed term: {any}", .{ c.getpid(), posix.errno(result) });
        GlobalState.requestShutdown();
        return;
    }
    result = c.sigaction(c.SIG.INT, &act, null);
    if (posix.errno(result) != .SUCCESS) {
        std.log.err("{d}: sigaction call failed int: {any}", .{ c.getpid(), posix.errno(result) });
        GlobalState.requestShutdown();
        return;
    }
}

const std = @import("std");
const builtin = @import("builtin");
const GlobalState = @import("GlobalState.zig");
const CliArgs = @import("CliArgs.zig");
const EventLoop = @import("EventLoop.zig");
const AcceptConnectionEvent = @import("./events/AcceptConnectionEvent.zig");
const c = std.c;
const posix = std.posix;
const socket = @import("socket.zig");
const Allocator = std.mem.Allocator;
const SocketError = socket.SocketError;
const native_os = builtin.os.tag;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const deinit = getAllocator();
    defer _ = if (deinit) debug_allocator.deinit();

    const server: [4]u8 = .{0} ** 4;
    const server_port: u16 = 8080;

    const server_fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var result = posix.errno(server_fd);
    if (result != .SUCCESS) {
        std.log.err("Call to socket failed: {any}", .{result});
        std.process.exit(1);
    }
    defer _ = c.close(server_fd);

    result = posix.errno(c.setsockopt(server_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &@as(u32, 1), @sizeOf(u32)));
    if (result != .SUCCESS) {
        std.log.err("call to setsockopt failed: {any}", .{result});
        std.process.exit(1);
    }
    const sock_addr_in: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .addr = @as(*align(1) const u32, @ptrCast(&server)).*,
        .port = std.mem.nativeToBig(u16, server_port),
    };
    result = posix.errno(c.bind(server_fd, @ptrCast(&sock_addr_in), @sizeOf(@TypeOf(sock_addr_in))));
    if (result != .SUCCESS) {
        std.log.err("call to bin dfailed: {any}", .{result});
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

    std.log.info("Waiting for client connection: \n", .{});

    var client_addr: posix.sockaddr.in = undefined;
    var client_addr_len: posix.socklen_t = @sizeOf(@TypeOf(client_addr));
    const client_fd = c.accept(server_fd, @ptrCast(&client_addr), &client_addr_len);
    result = posix.errno(client_fd);
    if (result != .SUCCESS) {
        std.log.err("call to accept failed: {any}", .{result});
        std.process.exit(1);
    }
    defer _ = c.close(client_fd);
    std.log.info("Connection from client accepted: {any}\n", .{client_addr});

    const BUFFER_SIZE = 4096;
    var buffer: [BUFFER_SIZE]u8 = .{0} ** BUFFER_SIZE;

    const read_count = c.read(client_fd, buffer[0..BUFFER_SIZE].ptr, BUFFER_SIZE);
    result = posix.errno(read_count);
    if (result != .SUCCESS) {
        std.log.err("call to read failed: {any}", .{result});
        std.process.exit(1);
    }
    const reply = std.fmt.allocPrint(gpa, "Reply to: {s}", .{buffer[0..@intCast(read_count)]}) catch unreachable;
    defer gpa.free(reply);

    result = posix.errno(c.send(client_fd, reply.ptr, reply.len, 0));
    if (result != .SUCCESS) {
        std.log.err("call to send failed, {any}", .{result});
        std.process.exit(1);
    }
}

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

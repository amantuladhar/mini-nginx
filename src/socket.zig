pub const SocketReader = @import("SocketReader.zig");

pub const SocketError = error{
    SocketInitFailed,
    ListenFailed,
    BindFailed,
    AcceptFailed,
    ReadFailed,
    WriteFailed,
    SetSocketOptionFailed,
    Interrupted,
    GetFlagFailed,
    SetFlagFailed,
};

pub fn readFromSocket(socket: i32, buffer: []u8) SocketError!usize {
    const read_count = c.read(socket, buffer[0..buffer.len].ptr, buffer.len);
    const result = posix.errno(read_count);
    if (result != .SUCCESS) return SocketError.ReadFailed;
    return @intCast(read_count);
}

pub fn sendToSocket(fd: usize, bytes: []const u8) SocketError!usize {
    const send_count = c.send(@intCast(fd), bytes[0..bytes.len].ptr, bytes.len, 0);
    const result = posix.errno(send_count);
    if (result != .SUCCESS) return SocketError.WriteFailed;
    return @as(usize, @intCast(send_count));
}

const GlobalState = @import("GlobalState.zig");
const c = std.c;
const posix = std.posix;
const std = @import("std");

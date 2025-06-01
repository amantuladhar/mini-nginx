// Hmm.. I kind of don't need to use atomic value as I won't have multiple threads
// I will fork child processes, and they will have their own copy of this variable.
// But to be safe just in case, maybe atomic is fine
var shutdown_requested = std.atomic.Value(bool).init(false);
var process_type = std.atomic.Value(u8).init(@intFromEnum(ProcessType.Parent));

const ProcessType = enum(u8) { Parent = 0, Child = 1 };

pub fn processType() ProcessType {
    return @enumFromInt(process_type.load(.acquire));
}

pub fn setProcessType(pt: ProcessType) void {
    process_type.store(@intFromEnum(pt), .release);
}

pub fn requestShutdown() void {
    shutdown_requested.store(true, .release);
}

pub fn isShutdownRequested() bool {
    return shutdown_requested.load(.acquire);
}

const std = @import("std");

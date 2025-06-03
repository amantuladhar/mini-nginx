pub const HttpStatusCode = enum(u16) {
    OK = 200,
    BadRequest = 400,
    Unauthorized = 401,
    Forbidden = 403,
    NotFound = 404,
    NotAllowed = 405,
    InternalServerError = 500,

    pub fn toString(self: @This()) []const u8 {
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

pub const HttpError = error{} || SocketError;

pub const HttpResponse = struct {
    status_code: HttpStatusCode,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: Allocator,

    raw: ArrayList,

    pub fn deinit(self: *@This()) void {
        self.raw.deinit();
        self.headers.deinit();
    }

    pub fn toBytes(self: *const @This()) []const u8 {
        return self.raw.items[0..self.raw.len];
    }

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

    pub fn readFromSocket(allocator: Allocator, fd: usize) HttpError!@This() {
        var buffer = ArrayList.init(allocator);
        var reader = SocketReader{ .fd = fd, .buffer = &buffer };

        const status_code = try parseStatusCode(&reader);
        const headers = try parseHeaders(allocator, &reader);
        const body: []u8 = if (headers.get("content-length")) |len| try reader.readExact(std.fmt.parseInt(u16, len, 10) catch unreachable) else "";
        return .{
            .status_code = status_code,
            .headers = headers,
            .body = body,
            .allocator = allocator,
            .raw = buffer,
        };
    }

    fn parseStatusCode(reader: *SocketReader) HttpError!HttpStatusCode {
        const line = try reader.readUntil('\n');
        var parts = std.mem.splitAny(u8, line, " ");
        _ = parts.next().?;
        const status_code = parts.next().?;
        const enum_value = std.fmt.parseInt(u16, std.mem.trim(u8, status_code, &std.ascii.whitespace), 10) catch unreachable;
        return @enumFromInt(enum_value);
    }
};

// @refactor - might have to update this implementation
// I don't like raw is here, this will make it hard to just create a request.
pub const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: Allocator,

    raw: ArrayList,

    pub fn deinit(self: *@This()) void {
        self.raw.deinit();
        self.headers.deinit();
    }

    pub fn toBytes(self: *const @This()) []const u8 {
        return self.raw.items[0..self.raw.len];
    }

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
        try writer.print(my_fmt, .{
            self.method,
            self.path,
            self.headers.count(),
            self.body,
            self.raw.items.len,
        });
    }

    pub fn readFromSocket(allocator: Allocator, fd: usize) HttpError!HttpRequest {
        var buffer = ArrayList.init(allocator);
        var reader = SocketReader{ .fd = fd, .buffer = &buffer };

        const status_line = try parseStatusLine(&reader);
        const headers = try parseHeaders(allocator, &reader);
        var body: ?[]u8 = null;
        if (headers.get("content-length")) |len| {
            body = try reader.readExact(std.fmt.parseInt(u16, len, 10) catch unreachable);
        }
        return .{
            .method = status_line.method,
            .path = status_line.path,
            .headers = headers,
            .body = body orelse "",
            .allocator = allocator,
            .raw = buffer,
        };
    }

    fn parseStatusLine(reader: *SocketReader) HttpError!struct { method: []const u8, path: []const u8 } {
        const line = try reader.readUntil('\n');
        var parts = std.mem.splitAny(u8, line, " ");
        const method = parts.next().?;
        const path = parts.next().?;
        return .{ .method = method, .path = path };
    }
};

fn parseHeaders(allocator: Allocator, reader: *SocketReader) HttpError!std.StringHashMap([]const u8) {
    // @todo - implement your own hashmap
    var map = std.StringHashMap([]const u8).init(allocator);
    var line = try reader.readUntil('\n');
    while (!std.mem.eql(u8, "\r\n", line)) {
        const key, const value = splitTwo(line, ':');
        toLower(key);
        map.put(
            std.mem.trim(u8, key, &std.ascii.whitespace),
            std.mem.trim(u8, value, &std.ascii.whitespace),
        ) catch unreachable;
        line = try reader.readUntil('\n');
    }
    return map;
}

fn toLower(slice: []u8) void {
    for (slice) |*it| {
        if (it.* >= 'A' and it.* <= 'Z') {
            it.* = it.* + 32;
        }
    }
}

fn splitTwo(source: []u8, delimiter: u8) struct { []u8, []u8 } {
    for (source, 0..) |it, i| {
        if (it == delimiter) {
            return .{
                source[0..i],
                source[i + 1 .. source.len],
            };
        }
    }
    return .{ source, "" };
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = @import("ArrayList.zig");
const SocketReader = @import("SocketReader.zig");
const socket = @import("socket.zig");
const SocketError = socket.SocketError;

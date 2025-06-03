port: u16 = 8080,
msg: []const u8 = "[server 1]",
proxy_port: ?u16 = null,
num_of_workers: u8 = 5,

const Self = @This();

pub fn parse() !Self {
    var args = std.process.args();
    _ = args.next();

    var cli_args: Self = .{};

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
        if (std.mem.eql(u8, "--num-of-workers", arg)) {
            const worker_count = args.next() orelse unreachable;
            cli_args.num_of_workers = try std.fmt.parseInt(u8, worker_count, 10);
            continue;
        }
    }
    return cli_args;
}
const std = @import("std");

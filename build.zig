const std = @import("std");

pub fn build(b: *std.Build) void {
    const t = b.standardTargetOptions(.{});
    const o = b.standardOptimizeOption(.{});

    const emod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = t, .optimize = o });
    const exe = b.addExecutable(.{ .name = "mini_nginx", .root_module = emod });

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |it| run_cmd.addArgs(it);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

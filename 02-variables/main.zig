const std = @import("std");

pub fn main() !void {
    const x: u32 = 2;
    var y: u32 = 3;

    y = x + y;

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "The sum is {d}\n", .{y});
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(msg);
}

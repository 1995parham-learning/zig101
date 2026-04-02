const std = @import("std");

pub fn main() !void {
    var buffer: [255]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&buffer);
    var reader = &stdin.interface;

    const n = try std.fmt.parseInt(i32, try reader.takeDelimiter('\n') orelse undefined, 10);

    std.debug.print("{d} = {d}\n", .{ n, fibonacci(n) });
}

fn fibonacci(n: i32) i32 {
    if (n == 1 or n == 2) {
        return 1;
    }

    return fibonacci(n - 1) + fibonacci(n - 2);
}

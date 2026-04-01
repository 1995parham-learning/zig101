const std = @import("std");

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "fmt error\n";
    const stdout = std.fs.File.stdout();
    stdout.writeAll(msg) catch {};
}

pub fn main() !void {
    // --- const vs var ---
    // `const` is immutable, `var` is mutable.
    const x: u32 = 2;
    var y: u32 = 3;
    y = x + y;
    print("const x = {d}, var y = x + y = {d}\n", .{ x, y });

    // --- type inference with @as ---
    // you can omit the type on the left side if the value is unambiguous.
    const inferred = 42; // comptime_int
    const explicit: u8 = @as(u8, 42);
    print("inferred = {d}, explicit u8 = {d}\n", .{ inferred, explicit });

    // --- undefined ---
    // `undefined` leaves memory uninitialized — useful for arrays/buffers
    // you plan to fill later. Reading before writing is safety-checked in
    // debug builds.
    var lazy: u32 = undefined;
    lazy = 10;
    print("lazy (was undefined, now set) = {d}\n", .{lazy});

    // --- shadowing is not allowed ---
    // unlike Rust, you cannot redeclare `x` in the same scope.
    // const x: u32 = 99;  // compile error: redeclaration

    // --- block scope ---
    // inner blocks can declare names that shadow outer ones.
    {
        const x_inner: u32 = 99;
        print("block-scoped x_inner = {d}\n", .{x_inner});
    }
    // x_inner is not accessible here.

    // --- optional types ---
    // a value that might be null. use `orelse` to unwrap with a default.
    var maybe: ?u32 = null;
    print("maybe (null) = {?d}\n", .{maybe});
    maybe = 7;
    const val = maybe orelse 0;
    print("maybe (set) = {d}, unwrapped = {d}\n", .{ maybe.?, val });

    // --- comptime variables ---
    // evaluated entirely at compile time, no runtime cost.
    comptime var i: u32 = 0;
    comptime {
        while (i < 5) : (i += 1) {}
    }
    print("comptime i after loop = {d}\n", .{i});

    // --- integer sizes and overflow ---
    // zig has fixed-width integers from u1 to u65535.
    const small: u4 = 15; // max value for 4-bit unsigned
    const big: u128 = 1 << 100;
    print("u4 max = {d}, u128 big = {d}\n", .{ small, big });

    // wrapping arithmetic with +% and -%
    const a: u8 = 255;
    const wrapped = a +% 1; // wraps to 0
    print("255 +%% 1 = {d} (wrapping)\n", .{wrapped});

    // saturating arithmetic with +| and -|
    const saturated = a +| 1; // stays at 255
    print("255 +| 1 = {d} (saturating)\n", .{saturated});

    // --- type coercion ---
    // smaller integers widen to larger ones automatically.
    const byte: u8 = 200;
    const wide: u32 = byte;
    print("u8 {d} widens to u32 {d}\n", .{ byte, wide });

    // truncation requires explicit @truncate.
    const back: u8 = @truncate(wide);
    print("u32 {d} truncated back to u8 {d}\n", .{ wide, back });
}

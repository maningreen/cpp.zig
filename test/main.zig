const std = @import("std");
const Testing = @import("testing");

export fn callstack() callconv(.c) void {
    std.debug.dumpCurrentStackTrace(.{});
}

pub fn main() !void {
    const t = Testing.Foo.Test2.init0();
    inline for (@typeInfo(@TypeOf(t)).@"struct".fields) |field| {
        const fval = @field(t, field.name);
        std.log.debug("t.{s}: {any}", .{ field.name, fval });
    }
}

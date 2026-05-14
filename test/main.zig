const std = @import("std");
const Testing = @import("testing");

export fn callstack() callconv(.c) void {
}

pub fn main() !void {
    var t = Testing.Foo.Test2.init0();
    defer t.deinit();
    inline for (@typeInfo(@TypeOf(t)).@"struct".fields) |field| {
        const fval = @field(t, field.name);
        std.log.debug("t.{s}: {any}", .{ field.name, fval });
    }
    t.testingFunction(30);
}

const std = @import("std");
const Testing = @import("testing");

pub fn main() !void {
    var t = Testing.Foo.Test2.init0();
    defer t.deinit();
    const j = t.constCastToTest();
    j.@"test"();
}

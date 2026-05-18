const std = @import("std");
const Testing = @import("testing");

pub fn main() !void {
    var t = Testing.Foo.Test2.init0();
    var j = Testing.Foo.@"Test<Bar>".init0();
    defer j.deinit();

    _ = j.testingFunction.testingFunctiond(30);
    defer t.deinit();
    t.testingFunction(30);
    _ = Testing.sum.sumff(30, 30);
    _ = Testing.sum.sumdd(30, 30);
}

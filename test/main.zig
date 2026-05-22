const std = @import("std");
const Testing = @import("testing");

pub fn main() !void {
    var t = Testing.Foo.Test2.init0();
    defer t.deinit();
    t.@"test"();
    t.testingFunction.testingFunctiond(30);
    t.testingFunction.testingFunctiond(31);
    t.castToTest().@"test"();
    _ = t._vtable._ZN3Foo5Test215testingFunctionEd(&t, 30);
    const j = t.constCastToTest();
    j.@"test"();
}

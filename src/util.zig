const std = @import("std");

pub fn isFundamental(comptime T: type) bool {
    return comptime switch (@typeInfo(T)) {
        .@"opaque",
        .null,
        .comptime_int,
        .comptime_float,
        .float,
        .int,
        .bool,
        .void,
        .type,
        .enum_literal,
        .@"enum",
        .error_set,
        .error_union,
        .@"fn",
        .noreturn,
        .frame,
        .@"anyframe",
        => true,
        else => false,
    };
}

pub fn ensure(x: bool) error{False}!void {
    if (!x) return error.False;
}

pub fn getBaseName(comptime T: type) [:0]const u8 {
    const returnval = comptime blk: {
        const full_name = @typeName(T);
        // Find the last index of '.'
        if (std.mem.lastIndexOfScalar(u8, full_name, '.')) |index| {
            break :blk full_name[index + 1 ..];
        }
        break :blk full_name;
    };
    return returnval;
}

pub fn tagToFieldName(comptime T: type) [:0]const u8 {
    return comptime blk: {
        const basename = getBaseName(T);
        const suffix = "s";

        // types have to have at least one character
        const lowercaseFirst = std.ascii.toLower(basename[0]);
        break :blk lowercaseFirst ++ basename[1..] ++ suffix;
    };
}

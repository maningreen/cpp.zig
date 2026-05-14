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
    comptime {
        const full_name = @typeName(T);
        // Find the last index of '.'
        if (std.mem.lastIndexOfScalar(u8, full_name, '.')) |index| {
            return full_name[index + 1 ..];
        }
        return full_name;
    }
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

/// asserts that T has a decl named `name`
pub fn DeclType(comptime T: type, comptime name: []const u8) type {
    switch (@typeInfo(T)) {
        .@"struct" => {
            const decl = @field(T, name);
            return @TypeOf(decl);
        },
        else => |_, t| @compileError("Error, type \"" ++ @typeName(T) ++ "\" is not a struct and is a " ++ @tagName(t)),
    }
}

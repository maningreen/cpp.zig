const std = @import("std");
const token = @import("token.zig");
const util = @import("util.zig");
const TokenContainer = @This();
const TokenUnion = token.TokenUnion;

data: Data,

pub const Data: type = blk: {
    const count: comptime_int = std.enums.values(token.type).len;
    var typeNames: [count][]const u8 = undefined;
    var typeAttrs: [count]std.builtin.Type.StructField.Attributes = undefined;
    var typeTypes: [count]type = undefined;
    for (std.enums.values(token.type), 0..) |value, i| {
        typeNames[i] = @tagName(value);
        typeTypes[i] = std.array_hash_map.String(token.StructType(value));
        typeAttrs[i] = std.builtin.Type.StructField.Attributes{
            .@"align" = null,
            .@"comptime" = false,
        };
    }
    break :blk @Struct(
        .auto,
        null,
        &typeNames,
        &typeTypes,
        &typeAttrs,
    );
};

pub fn init() TokenContainer {
    var self: TokenContainer = undefined;
    inline for (@typeInfo(Data).@"struct".fields) |value|
        @field(self.data, value.name) = .empty;
    return self;
}

pub fn get(self: @This(), comptime t: token.type) std.array_hash_map.String(token.StructType(t)) {
    return @field(self.data, @tagName(t));
}
pub fn appendExplicit(self: *@This(), gpa: std.mem.Allocator, comptime t: type, value: token.StructType(t)) !void {
    return @field(self.data, @tagName(t)).append(gpa, value);
}

pub fn append(self: *@This(), gpa: std.mem.Allocator, value: anytype) !void {
    const inType = @TypeOf(value);
    util.ensure(@hasField(@TypeOf(self.data), util.getBaseName(inType))) catch {
        @panic("Error! " ++ comptime util.getBaseName(inType) ++ " is not acceptable!");
    };

    try @field(self.data, util.getBaseName(inType)).put(gpa, value.id, value);
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    inline for (comptime std.enums.values(token.type)) |t| {
        for (@field(self.data, @tagName(t)).values()) |*value|
            token.deinitToken(@TypeOf(value.*))(value, gpa);
        @field(self.data, @tagName(t)).deinit(gpa);
    }
}

pub fn getType(self: @This(), id: []const u8) ?token.type {
    inline for (@typeInfo(Data).@"struct".fields, std.enums.values(token.type)) |field, tokenType| {
        const set = @field(self.data, field.name);
        if (set.contains(id))
            return tokenType;
    }
    return null;
}
pub fn find(self: @This(), id: []const u8) ?TokenUnion {
    inline for (std.enums.values(token.type)) |tokenType|
        if (@field(self.data, @tagName(tokenType)).get(id)) |val|
            return @unionInit(TokenUnion, @tagName(tokenType), val);
    return null;
}

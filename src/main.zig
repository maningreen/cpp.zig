const std = @import("std");
const xml = @import("xml");
const TokenContainer = @import("container.zig");
const token = @import("token.zig");
const util = @import("util.zig");

/// Caller owns memory
fn getAST(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const argv = &.{ "castxml", "--castxml-output=1", path, "-o", "-" };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stderr = .close, // why is this ignore? well, because we want to ignore global headers.
        .cwd = .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
    });
    const file = child.stdout orelse unreachable;
    var readBuf: [1028]u8 = undefined;
    var stdin = file.reader(io, &readBuf);
    var contents: []u8 = try gpa.alloc(u8, try file.length(io));
    errdefer gpa.free(contents);
    while (true) {
        const line = try stdin.interface.takeDelimiter('\n') orelse break;
        contents = try gpa.realloc(contents, contents.len + line.len + 1);
        std.mem.copyForwards(u8, contents[contents.len - (line.len + 1) ..], line);
        contents[contents.len - 1] = '\n';
    }
    const c = try child.wait(io);
    switch (c) {
        .stopped, .signal => |v| {
            std.log.info("return code: {any}", .{v});
            return error.Signal;
        },
        .exited => |e| {
            if (e != 0) {
                std.log.info("Return code: {d}", .{e});
                return error.ExitCode;
            }
        },
        .unknown => return error.Unknown,
    }
    return contents;
}

fn isInFieldArray(comptime T: type, itemType: []const u8) ?std.meta.FieldEnum(T) {
    comptime std.debug.assert(@typeInfo(T) == .@"struct");

    inline for (@typeInfo(T).@"struct".fields, std.enums.values(std.meta.FieldEnum(T))) |field, e| {
        const info = @typeInfo(field.type);
        switch (info) {
            .pointer => |ptr| {
                if (ptr.size != .slice) continue;
                const childName = comptime util.getBaseName(ptr.child);
                if (std.mem.eql(u8, childName, itemType))
                    return e;
            },
            else => continue,
        }
    }
    return null;
}

fn fieldInfo(comptime T: type, comptime fieldTag: std.meta.FieldEnum(T)) std.builtin.Type.StructField {
    if (@typeInfo(T) != .@"struct") @compileError(@typeName(T) ++ " is not of type struct!");

    const tagname = comptime @tagName(fieldTag);

    for (@typeInfo(T).@"struct".fields) |field| {
        @setEvalBranchQuota(5000);
        if (comptime std.mem.eql(u8, field.name, tagname)) {
            return field;
        }
    }
    @compileError("fieldTag of type " ++ @tagName(T) ++ " does not exist in the struct!");
}

/// returned memory is owned by caller.
fn parseTokens(gpa: std.mem.Allocator, input: []const u8) !TokenContainer {
    var xmlReader = std.Io.Reader.fixed(input);

    var streamingReader: xml.Reader.Streaming = .init(gpa, &xmlReader, .{});
    defer streamingReader.deinit();

    const reader = &streamingReader.interface;

    var container = TokenContainer.init();
    errdefer container.deinit(gpa);

    var state: ?token.TokenUnion = null;
    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => {
                const loc = reader.errorLocation();
                std.log.err("{}:{}: {}", .{ loc.line, loc.column, reader.errorCode() });
                return error.MalformedXml;
            },
            else => return err,
        };
        switch (node) {
            .eof => {
                break;
            },
            .element_start => {
                const element_name = reader.elementNameNs();
                const t = token.getItem(element_name.local);

                if (state != null) {
                    switch (state.?) {
                        inline else => |*s| {
                            const T = @TypeOf(s.*);
                            if (isInFieldArray(T, element_name.local)) |v| {
                                switch (v) {
                                    inline else => |tag| {
                                        const info = comptime fieldInfo(T, tag);
                                        switch (@typeInfo(info.type)) {
                                            .pointer => |p| {
                                                if (@typeInfo(p.child) != .@"struct")
                                                    continue;
                                                const args = &@field(s.*, info.name);
                                                args.* = try gpa.realloc(args.*, args.len + 1);
                                                const TPrime = p.child;
                                                var arg: TPrime = undefined;
                                                for (0..reader.attributeCount()) |i| {
                                                    const attribute_name = reader.attributeNameNs(i);
                                                    const value = try reader.attributeValue(i);
                                                    try token.setValue(TPrime, &arg, gpa, attribute_name.local, value);
                                                }
                                                args.*[args.len - 1] = arg;
                                            },
                                            else => continue,
                                        }
                                    },
                                }
                                continue;
                            }
                        },
                    }
                    continue;
                }
                switch (t orelse continue) {
                    inline else => |v| {
                        const T = token.StructType(v);
                        var m: T = undefined;
                        inline for (@typeInfo(T).@"struct".fields) |field| {
                            if (field.defaultValue()) |d| @field(m, field.name) = d;
                        }
                        for (0..reader.attributeCount()) |i| {
                            const attribute_name = reader.attributeNameNs(i);
                            const value = try reader.attributeValue(i);
                            try token.setValue(comptime token.StructType(v), &m, gpa, attribute_name.local, value);
                        }
                        state = @unionInit(token.TokenUnion, util.getBaseName(T), m);
                    },
                }
            },
            .element_end => {
                if (state) |s| switch (s) {
                    inline else => |v| {
                        if (isInFieldArray(@TypeOf(v), reader.elementName())) |_|
                            continue;
                    },
                };

                switch (state orelse continue) {
                    inline else => |v| try container.append(gpa, v),
                }

                state = null;
            },
            else => continue,
        }
    }
    return container;
}

fn printFile(io: std.Io, gpa: std.mem.Allocator, out: *std.Io.Writer, file: []const u8) !void {
    const ret = try getAST(io, gpa, file);
    defer gpa.free(ret);
    if (ret.len <= 2) {
        try out.print("", .{});
        return;
    }
    var container = try parseTokens(gpa, ret);
    defer container.deinit(gpa);
    try token.Namespace.write(null, gpa, container, out);
}

pub fn main(init: std.process.Init) !void {
    if (init.minimal.args.vector.len == 1) return;
    const file = std.Io.File.stdout();
    defer file.close(init.io);
    var writeBuf: [1028]u8 = undefined;
    var writer = file.writer(init.io, &writeBuf);
    for (init.minimal.args.vector[1..]) |arg| {
        const l = std.mem.len(arg);
        try printFile(init.io, init.gpa, &writer.interface, arg[0..l]);
    }
    try writer.flush();
}

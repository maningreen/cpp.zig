const std = @import("std");
const xml = @import("xml");
const TokenContainer = @import("container.zig");
const token = @import("token.zig");
const util = @import("util.zig");

/// Caller owns memory
/// returns the output, and stderr of the program
fn getAST(io: std.Io, gpa: std.mem.Allocator, path: []const u8, flags: []const []const u8) ![]u8 {
    const argv =
        try std.mem.concat(
            gpa,
            []const u8,
            &.{
                &.{ "castxml", "--castxml-output=1", path, "-o", "-" },
                &.{ "--castxml-cc-gnu", "(", "zig", "c++" },
                flags,
                &.{")"},
            },
        );
    defer gpa.free(argv);
    std.log.info("Started castxml", .{});
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stderr = .inherit,
        .cwd = .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
    });
    std.log.info("Ended Castxml", .{});
    const file = child.stdout orelse unreachable;
    var buf: [1028]u8 = undefined;
    var stdin = file.reader(io, &buf);
    std.log.info("Started buffering", .{});
    const contents = try stdin.interface.allocRemaining(gpa, .unlimited);
    std.log.info("Ended buffering", .{});
    errdefer gpa.free(contents);
    const c = try child.wait(io);
    switch (c) {
        .stopped, .signal => |v| {
            std.log.info("return code: {any}", .{v});
            return error.Signal;
        },
        .exited => |e| {
            if (e != 0) {
                std.log.info("Return code: {d}", .{e});
                for (argv) |a|
                    std.log.debug("Argument: {s}", .{a});
                std.log.debug("command: ", .{});
                for (argv) |a|
                    std.debug.print("{s} ", .{a});
                std.debug.print("\n", .{});
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
        if (comptime std.mem.eql(u8, field.name, tagname))
            return field;
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
                            @setEvalBranchQuota(10000);
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

fn printFile(io: std.Io, gpa: std.mem.Allocator, out: *std.Io.Writer, file: []const u8, args: []const []const u8) !void {
    const ret = try getAST(io, gpa, file, args);
    defer gpa.free(ret);
    if (ret.len <= 2) {
        try out.print("", .{});
        return;
    }
    std.log.info("Parsing tokens...", .{});
    var container = try parseTokens(gpa, ret);
    defer container.deinit(gpa);
    std.log.info("Done parsing tokens", .{});
    std.log.info("Printing to stdout", .{});
    try token.Namespace.write(null, gpa, container, try token.Namespace.Context.init(gpa, container), out);
}

fn arrayCast(
    comptime In: type,
    comptime Out: type,
    gpa: std.mem.Allocator,
    in: []const In,
    comptime cast: fn (anytype) Out,
) ![]Out {
    const arr = try gpa.alloc(Out, in.len);
    for (in, 0..) |v, i|
        arr[i] = cast(v);
    return arr;
}

pub fn main(init: std.process.Init) !void {
    if (init.minimal.args.vector.len == 1) return;
    const file = std.Io.File.stdout();
    defer file.close(init.io);
    var writeBuf: [1028]u8 = undefined;
    var writer = file.writer(init.io, &writeBuf);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const xmlArgs, const argsI = for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) break .{ args[i + 1 ..], i };
    } else .{ &.{}, args.len };

    for (args[1..argsI]) |arg|
        try printFile(init.io, init.gpa, &writer.interface, arg, xmlArgs);

    try writer.interface.flush();
}

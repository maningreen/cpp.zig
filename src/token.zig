const std = @import("std");
const debug = std.debug;
const TokenContainer = @import("container.zig");
const util = @import("util.zig");

/// prints out the types of a function
pub fn generateTypeSig(f: anytype, gpa: std.mem.Allocator, data: TokenContainer) ![]u8 {
    comptime {
        debug.assert(@hasField(@TypeOf(f), "arguments"));
        debug.assert(@FieldType(@TypeOf(f), "arguments") == []Argument);
    }

    var writer: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(gpa);
    errdefer writer.deinit();

    for (f.arguments) |arg| {
        const str = try arg.printName(gpa, data);
        defer gpa.free(str);
        try writer.writer.print("{s}", .{str});
    }

    return writer.toOwnedSlice();
}

fn writeMangledArguments(
    args: []const Argument,
    gpa: std.mem.Allocator,
    data: TokenContainer,
) (DataSearch || std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    var writer = std.Io.Writer.Allocating.init(gpa);

    for (args) |arg| {
        var argType: []const u8 = arg.type;
        while (true) {
            switch ((data.find(argType) orelse {
                std.log.err("missing id: {s}", .{argType});
                return DataSearch.MissingID;
            })) {
                .FundamentalType => |fund| {
                    const value = typeMap.get(fund.name) orelse debug.panic("reached invalid type: {s}", .{fund.name});
                    try writer.writer.print("{s}", .{value.@"0"});
                    break;
                },
                inline .ArrayType, .PointerType => |ptr| {
                    try writer.writer.print("P", .{});
                    argType = ptr.type;
                },
                .ReferenceType => |ref| {
                    try writer.writer.print("R", .{});
                    argType = ref.type;
                },
                inline .Union, .Class, .Struct => |cplx| {
                    try writer.writer.print("{d}{s}", .{ cplx.name.len, cplx.name });
                    break;
                },
                .CvQualifiedType => |cv| {
                    try writer.writer.print("{s}", .{if (cv.@"const") "K" else ""});
                    argType = cv.type;
                },
                .FunctionType => |f| {
                    const t = try f.writeMangledTypeSig(gpa, data);
                    defer gpa.free(t);
                    try writer.writer.print("{s}", .{t});
                },
                inline .ElaboratedType, .Typedef => |td| {
                    argType = td.type;
                },
                else => |_, tag| std.debug.panic("Reached invalid argument of type {s}", .{@tagName(tag)}),
            }
        }
    } else {
        // the only way to get here is if there're no arguments
        // we break from every other case
        try writer.writer.print(comptime typeMap.get("void").?.@"0", .{});
    }
    return writer.toOwnedSlice();
}

const typeMap = std.static_string_map.StaticStringMap(struct { []const u8, enum {
    custom,
    primitive,
} }).initComptime(&.{
    .{ "void", .{ "v", .primitive } },
    .{ "wchar_t", .{ "w", .primitive } },
    .{ "bool", .{ "b", .primitive } },
    .{ "char", .{ "c", .primitive } },
    .{ "signed char", .{ "a", .primitive } },
    .{ "unsigned char", .{ "h", .primitive } },
    .{ "short", .{ "s", .primitive } },
    .{ "unsigned short", .{ "t", .primitive } },
    .{ "short unsigned int", .{ "t", .primitive } },
    .{ "int", .{ "i", .primitive } },
    .{ "unsigned int", .{ "j", .primitive } },
    .{ "long", .{ "l", .primitive } },
    .{ "unsigned long", .{ "m", .primitive } },
    .{ "long unsigned int", .{ "m", .primitive } },
    .{ "long long", .{ "x", .primitive } },
    .{ "unsigned long long", .{ "y", .primitive } },
    .{ "__int128", .{ "n", .primitive } },
    .{ "unsigned __int128", .{ "o", .primitive } },
    .{ "float", .{ "f", .primitive } },
    .{ "double", .{ "d", .primitive } },
    .{ "long double", .{ "e", .primitive } },
    .{ "__float128", .{ "g", .primitive } },
    .{ "char32_t", .{ "Di", .primitive } },
    .{ "char16_t", .{ "Ds", .primitive } },
    .{ "auto", .{ "Da", .primitive } },
    .{ "std::nullptr_t", .{ "Dn", .primitive } },
});

pub const Access = enum {
    public,
    private,
    protected,
};

pub const @"type" = enum {
    Method,
    Class,
    Struct,
    FundamentalType,
    Field,
    Constructor,
    Enumeration,
    PointerType,
    ReferenceType,
    RValueReferenceType,
    Destructor,
    Namespace,
    Typedef,
    ArrayType,
    CvQualifiedType,
    Function,
    Variable,
    ElaboratedType,
    Union,
    AtomicType,
    FunctionType,
};

pub const Method = struct {
    name: []u8,
    mangled: []u8 = "",
    id: []u8,
    returns: []u8,
    overrides: ?[]u8 = null,
    // context: []u8,
    arguments: []Argument = &.{},
    access: Access,
    virtual: bool,
    line: u64,
    @"inline": bool,
    @"const": bool,
};

pub const Class = struct {
    name: []u8 = "",
    members: []u8 = "",
    id: []u8,
    context: []u8,
    size: u64,
    @"align": u64,
    bases: []Base = &.{},
    incomplete: bool = false,

    pub const Context = struct {
        const DataType = std.hash_map.StringHashMapUnmanaged(ClassData);
        const ClassData = std.hash_map.StringHashMapUnmanaged(MethodData);
        const MethodData = std.array_list.Aligned([]const u8, null);

        data: DataType,

        /// returns number of overloads `methodName` has
        /// searches bases
        pub fn overloadCount(self: Context, data: TokenContainer, classId: []const u8, methodName: []const u8) ?u64 {
            const class = switch (data.find(classId) orelse return null) {
                .Class, .Struct => |c| c,
                else => return null,
            };

            const classData = self.data.get(classId) orelse return null;
            const method = classData.get(methodName) orelse return null;

            var baseCount: u64 = 0;
            for (class.bases) |base|
                baseCount += self.overloadCount(data, base.type, methodName) orelse 0;

            return method.items.len + baseCount;
        }

        pub fn init(gpa: std.mem.Allocator, tokens: TokenContainer) !Context {
            var data: DataType = .empty;

            for (tokens.get(.Class).values()) |class| {
                var classData = ClassData.empty;
                var memberIt = class.memberIterator();
                while (memberIt.next()) |memberId| {
                    switch (tokens.find(memberId) orelse continue) {
                        .Method => |method| {
                            const r = try classData.getOrPut(gpa, method.name);
                            if (!r.found_existing) {
                                r.value_ptr.* = .empty;
                            }
                            try r.value_ptr.append(gpa, method.id);
                        },
                        else => continue,
                    }
                }
                try data.put(gpa, class.id, classData);
            }
            return .{ .data = data };
        }

        pub fn deinit(self: *Context, gpa: std.mem.Allocator) void {
            var it = self.data.valueIterator();
            while (it.next()) |v| {
                var it2 = v.valueIterator();
                while (it2.next()) |a| {
                    a.deinit(gpa);
                }
                v.deinit(gpa);
            }
            self.data.deinit(gpa);
        }
    };

    const vtableName = "_vtable";
    const vtableType = "Vtable";

    const overloadTableFmt = "Overloaded_{s}";

    const Base = struct {
        type: []u8,
        access: Access,
        virtual: bool,
        offset: u64,
    };

    pub fn memberIterator(self: Class) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, self.members, ' ');
    }

    const selfTag = std.meta.stringToEnum(@"type", util.getBaseName(@This())) orelse unreachable;

    pub fn write(
        self: Class,
        gpa: std.mem.Allocator,
        data: TokenContainer,
        context: Context,
        writer: *std.Io.Writer,
    ) !void {
        if (self.incomplete) return;

        try writer.print(
            \\const @"{s}" = extern struct {{
            \\
        , .{self.id});

        // 1 -> generate a vtable structure
        // 2 -> print fields
        // 3 -> print callables (and virtuals)

        // Stage 1 -> generate a vtable.
        try writer.print(std.fmt.comptimePrint(
            \\const {s} = extern struct {{{{
            \\
        , .{vtableType}), .{});
        const virtualItems: bool = try writeVtableFields(self, gpa, data, context, writer);
        try writer.print(
            \\}};
            \\
        , .{});

        // Phase 2 -> print fields
        {
            if (virtualItems) {
                try writer.print("{s}: *const @\"{s}\",\n", .{
                    vtableName,
                    vtableType,
                });
            }
            try self.writeFields(data, gpa, writer);
        }

        // phase 2.5 -> print out overloaded fake members
        try self.writeOverloadFields(gpa, data, context, writer);

        // Phase 3 -> print functions
        //
        // part 1: print constructors & destructors
        {
            var it = self.memberIterator();
            var initIterator: u64 = 0;
            while (it.next()) |member| {
                switch (data.find(member) orelse continue) {
                    .Constructor => |constructor| {
                        switch (constructor.access) {
                            .public => {
                                if (!constructor.@"inline") {
                                    defer initIterator += 1;

                                    const mangled = try constructor.writeMangled(initIterator, gpa, data);
                                    defer gpa.free(mangled);

                                    try writer.print(
                                        \\pub fn init{d}(
                                    , .{initIterator});

                                    for (constructor.arguments, 0..) |arg, i| {
                                        const name = try namespacedType(arg.type, data, gpa) orelse continue;
                                        defer gpa.free(name);
                                        try writer.print("_{d}: {s}, ", .{ i, name });
                                    }

                                    try writer.print(
                                        \\) @This() {{
                                        \\  var t: [{d}]u8 align({d}) = undefined;
                                        \\  @"{s}"(@ptrCast(&t),
                                    , .{ @divExact(self.size, 8), @divExact(self.@"align", 8), mangled });

                                    for (constructor.arguments, 0..) |_, i|
                                        try writer.print("_{d}, ", .{i});

                                    try writer.print(
                                        \\);
                                        \\  return @as(*@This(), @ptrCast(&t)).*;
                                        \\}}
                                        \\
                                    , .{});

                                    try writer.print("extern \"c\" fn @\"{s}\"(*@This(), ", .{mangled});
                                    for (constructor.arguments) |arg|
                                        try writer.print("{s}, ", .{arg.type});
                                    try writer.print(") callconv(.c) void;\n", .{});
                                }
                            },
                            else => continue,
                        }
                    },
                    .Destructor => |destructor| {
                        if (!(destructor.@"inline" or destructor.virtual)) {
                            try destructor.writeMangled(gpa, data, writer);
                        } else if (destructor.virtual) {
                            // + 2 for the complete & partial destructors
                            try writer.print(
                                \\pub fn deinit(self: *const @This()) void {{
                                \\    const completeDestructor =
                                \\        self.{s}.destruct;
                                \\    completeDestructor(self);
                                \\}}
                                \\
                            , .{vtableName});
                        }
                    },

                    else => continue,
                }
            }
        }

        {
            var it = self.memberIterator();
            while (it.next()) |memberID| {
                switch (data.find(memberID) orelse continue) {
                    .Typedef => |td| {
                        const name = try namespacedType(td.type, data, gpa) orelse continue;
                        defer gpa.free(name);

                        try writer.print("pub const @\"{s}\" = {s};\n", .{ td.name, name });
                    },
                    else => continue,
                }
            }
        }
        {
            const methodData = context.data.get(self.id) orelse return DataSearch.MissingID;
            const methods = try self.concatMethods(gpa, data, context);
            defer gpa.free(methods);
            for (methods) |method| {
                // we overloaded exception, we manage later
                if (methodData.get(method.name)) |v|
                    if (v.items.len > 1) continue;
                // inline methods have no labels, so we can't link
                if (method.@"inline") continue;
                // we won't print it, it's internal only
                if (method.access != .public) continue;
                const prefix = if (method.@"const") "const " else "";
                if (context.overloadCount(data, self.id, method.name) orelse 0 > 1) continue;
                if (method.virtual) {
                    try writer.print(
                        \\pub inline fn {s}(self: *{s}@This(),
                    , .{ method.name, prefix });
                    for (method.arguments, 0..) |arg, i| {
                        try writer.print(
                            \\arg{d}: {s}, 
                        , .{ i, arg.type });
                    }
                    try writer.print(
                        \\) {s} {{
                        \\    return self.{s}.{s}(self, 
                    , .{ method.returns, vtableName, method.mangled });
                    for (method.arguments, 0..) |_, i| {
                        try writer.print(
                            \\arg{d},
                        , .{i});
                    }
                    try writer.print(
                        \\);
                        \\}}
                        \\
                    , .{});
                } else {
                    try writer.print(
                        \\extern "c" fn @"{s}" (*{s}@This(), 
                    , .{ method.mangled, prefix });
                    for (method.arguments) |arg| {
                        try writer.print("{s}, ", .{arg.type});
                    }
                    try writer.print(
                        \\) {s};
                        \\pub const @"{s}" = {s};
                        \\
                    , .{ method.returns, method.name, method.mangled });
                }
            }
        }

        // funky overloaded function time
        try self.writeOverloadStructs(gpa, data, context, writer);

        try self.writeParentCastFunctions(gpa, data, writer);

        try writer.print("}};\n", .{});
        if (self.name.len != 0) {
            try writer.print(
                \\pub const @"{s}" = @"{s}";
                \\
            , .{ self.name, self.id });
        }
    }

    /// prints out all of the fields of the class,
    /// and the inherited members
    /// does *not* print _vtable
    pub fn writeFields(self: Class, data: TokenContainer, gpa: std.mem.Allocator, writer: *std.Io.Writer) (DataSearch || std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        var it = self.memberIterator();
        var privateIterator: u64 = 0;
        for (self.bases) |baseID| {
            const base = data.find(baseID.type) orelse continue;
            switch (base) {
                .Class, .Struct => |baseClass| {
                    switch (baseID.access) {
                        .private, .protected => {
                            try writer.print("_{d}: [{d}]u8 align({d}),\n", .{ privateIterator, baseClass.size, baseClass.@"align" / 8 });
                            privateIterator += 1;
                        },
                        .public => {
                            try baseClass.writeFields(data, gpa, writer);
                        },
                    }
                },
                else => unreachable,
            }
        }

        var fieldList = std.ArrayList(Field).empty;
        defer fieldList.deinit(gpa);
        while (it.next()) |memberid| {
            switch (data.find(memberid) orelse continue) {
                .Field => |f| {
                    try fieldList.append(gpa, f);
                },
                else => continue,
            }
        }

        const cmp = struct {
            pub fn lt(_: void, a: Field, b: Field) bool {
                return a.offset < b.offset;
            }
        }.lt;

        std.mem.sort(Field, fieldList.items, void{}, cmp);

        for (fieldList.items) |field| {
            // explicit padding
            if (field.name.len == 0) {
                const size, const alignment =
                    try getTypeSize(field, data) orelse continue;
                try writer.print("_{d}: [{d}]u8 align({d}),\n", .{ privateIterator, size, alignment });
                privateIterator += 1;
            } else switch (field.access) {
                .public => {
                    try writer.print("@\"{s}\": {s},\n", .{ field.name, field.type });
                },
                .protected, .private => {
                    const size, const alignment =
                        try getTypeSize(field, data) orelse continue;
                    try writer.print("_{d}: [{d}]u8 align({d}),\n", .{ privateIterator, size, alignment });
                    privateIterator += 1;
                },
            }
        }
    }

    /// Example:
    /// A `Class` representing the following
    /// ```cpp
    /// class Foo {
    ///     int item;
    ///     virtual void function(void);
    /// };
    /// ```
    /// and an ample `data` structure, will lead to the following being written to `writer`
    /// ```zig
    /// function: *const fn (void) void,
    /// ```
    /// returns whether or not it wrote anything, for a class without virtual members,
    /// simply returns false,
    pub fn writeVtableFields(self: Class, gpa: std.mem.Allocator, data: TokenContainer, ctx: Context, writer: *std.Io.Writer) !bool {
        const items = try compileVirtual(self, gpa, data, ctx);
        defer gpa.free(items);

        if (items.len == 0)
            return false;

        for (items) |item| {
            switch (item) {
                .Destructor => |d| {
                    debug.assert(d.virtual);
                    try writer.print(
                        \\destruct: *const fn (*const @"{s}") callconv(.c) void,
                        \\delete: *const fn (*const @"{s}") callconv(.c) void,
                        \\
                    , .{ self.name, self.name });
                },
                .Method => |m| {
                    debug.assert(m.virtual);
                    const constStr = if (m.@"const") "const" else "";

                    try writer.print(
                        \\@"{s}": *const fn (*{s} @"{s}",
                        \\
                    , .{
                        m.mangled,
                        constStr,
                        self.name,
                    });
                    for (m.arguments) |arg|
                        try writer.print("{s}, ", .{arg.type});

                    try writer.print(
                        \\) callconv(.c) {s},
                        \\
                    , .{m.returns});
                },
            }
        }
        return true;
    }

    const VirtualUnion = union(enum) {
        Destructor: Destructor,
        Method: Method,
    };

    /// returns a slice of all the virtual items, sorted
    pub fn compileVirtual(self: Class, gpa: std.mem.Allocator, data: TokenContainer, ctx: Context) ![]VirtualUnion {
        var arrList = std.ArrayList(VirtualUnion).empty;
        errdefer arrList.deinit(gpa);
        var it = self.memberIterator();
        while (it.next()) |member| {
            switch (data.find(member) orelse continue) {
                .Destructor,
                => |v| if (v.virtual) try arrList.append(gpa, .{ .Destructor = v }),
                else => continue,
            }
        }

        const methods = try self.concatMethods(gpa, data, ctx);
        defer gpa.free(methods);
        for (methods) |val| {
            if (val.virtual)
                try arrList.append(gpa, .{ .Method = val });
        }

        if (arrList.items.len == 0) return arrList.toOwnedSlice(gpa) catch unreachable;

        const cmp = struct {
            pub fn lt(_: void, aP: VirtualUnion, bP: VirtualUnion) bool {
                switch (aP) {
                    inline else => |a| {
                        switch (bP) {
                            inline else => |b| {
                                return a.line >= b.line;
                            },
                        }
                    },
                }
            }
        }.lt;
        std.mem.sort(VirtualUnion, arrList.items, void{}, cmp);

        return arrList.toOwnedSlice(gpa);
    }

    /// Given the following c++ class, and ample `ctx` and `data`, will write the given output
    /// ```cpp
    /// class MyClass {
    ///     void myFunc2();
    ///
    ///     void myFunc(int);
    ///     void myFunc(float);
    /// }
    /// ```
    /// the following would be written to the inputted writer
    /// ```zig
    ///   myFunc: (overloadTableFmt)
    /// ```
    /// where `(overloadTableFmt)` is the format for overload tables, with `"myFunc"` as the item
    pub fn writeOverloadFields(
        self: Class,
        gpa: std.mem.Allocator,
        data: TokenContainer,
        ctx: Context,
        out: *std.Io.Writer,
    ) (DataSearch || std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        var methods = try compileMethods(self, gpa, data, ctx);
        defer methods.deinit(gpa);

        var it = methods.iterator();
        while (it.next()) |entry| {
            defer entry.value_ptr.deinit(gpa);

            if (entry.value_ptr.items.len > 1) {
                try out.print(
                    \\@"{s}": 
                ++ overloadTableFmt ++
                    \\,
                    \\
                , .{ entry.key_ptr.*, entry.key_ptr.* });
            }
        }
    }

    /// Given the following c++ class, and ample `ctx` and `data`, will write the given output
    /// ```cpp
    /// class MyClass {
    ///     void myFunc2();
    ///
    ///     void myFunc(int);
    ///     void myFunc(float);
    /// }
    /// ```
    /// the following would be written to the inputted writer
    /// ```zig
    /// pub const (overloadTableFmt) = extern struct {
    ///     pub inline fn myFunci(self: *(overloadTableFmt), arg_0: i) void {
    ///          const parent = @as((MyClass.id), @fieldParentPtr("myFunc", self));
    ///          return _ZN7MyClass6myFuncEi(parent, arg_0);
    ///     }
    ///     extern fn _ZN7MyClass6myFuncEi(*MyClass, i32) callconv(.c) void;
    ///     pub inline fn myFuncd(self: *(overloadTableFmt), arg_0: i) void {
    ///          const parent = @as((MyClass.id), @fieldParentPtr("myFunc", self));
    ///          return _ZN7MyClass6myFuncEd(parent, arg_0);
    ///     }
    ///     extern fn _ZN7MyClass6myFuncEd(*MyClass, i32) callconv(.c) void;
    /// }
    /// ```
    /// where `(overloadTableFmt)` is the format for overload tables, with `"myFunc"` as the item
    pub fn writeOverloadStructs(
        self: Class,
        gpa: std.mem.Allocator,
        data: TokenContainer,
        ctx: Context,
        out: *std.Io.Writer,
    ) (DataSearch || std.mem.Allocator.Error || std.Io.Writer.Error || Argument.PrintError)!void {
        var methods = try self.compileMethods(gpa, data, ctx);
        defer {
            defer methods.deinit(gpa);
            var it = methods.valueIterator();
            while (it.next()) |v|
                v.deinit(gpa);
        }
        var it = methods.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.items.len < 2) {
                continue;
            }
            // overload
            try out.print(
                \\pub const 
            ++ overloadTableFmt ++
                \\ = extern struct {{
                \\
            , .{entry.key_ptr.*});
            for (entry.value_ptr.items) |methodId| {
                const method = data.get(.Method).get(methodId) orelse return DataSearch.MissingID;
                const sig = try generateTypeSig(method, gpa, data);
                const prefix = if (method.@"const") "const " else "";
                defer gpa.free(sig);
                //     pub inline fn myFunci(self: *(overloadTableFmt), arg_0: i) void {
                //          const parent = @as(*(MyClass.id), @fieldParentPtr("myFunc", self));
                //          return _ZN7MyClass6myFuncEi(parent, arg_0);
                //     }
                try out.print(
                    \\pub inline fn @"
                ++ overloadTableFmt ++
                    \\{s}"(self: *{s}
                ++ overloadTableFmt ++
                    \\, 
                , .{ method.name, sig, prefix, method.name });

                for (method.arguments, 0..) |arg, i| {
                    try out.print(
                        \\arg_{d}: {s},
                        \\
                    , .{
                        i,
                        arg.type,
                    });
                }

                if (method.virtual) {
                    try out.print(
                        \\) {s} {{
                        \\    const parent = @as(*{s}@"{s}", @alignCast(@fieldParentPtr("{s}", self)));
                        \\    return parent.{s}.{s}(parent, 
                    , .{
                        method.returns,
                        prefix,
                        self.name,
                        method.name,
                        vtableName,
                        method.mangled,
                    });
                } else {
                    try out.print(
                        \\) {s} {{
                        \\    const parent = @as(*{s}@"{s}", @alignCast(@fieldParentPtr("{s}", self)));
                        \\    return @"{s}"(parent, 
                    , .{
                        method.returns,
                        prefix,
                        self.name,
                        method.name,
                        method.mangled,
                    });
                }
                for (method.arguments, 0..) |_, i| {
                    try out.print(
                        \\arg_{d},
                        \\
                    , .{
                        i,
                    });
                }
                try out.print(
                    \\);
                    \\}}
                    \\
                , .{});
                try out.print(
                    \\extern "c" fn @"{s}" (*{s}@"{s}", 
                , .{ method.mangled, prefix, self.name });
                for (method.arguments) |arg| {
                    try out.print("{s}, ", .{arg.type});
                }
                try out.print(
                    \\) {s};
                    \\
                , .{method.returns});
            }
            try out.print("}};\n", .{});
        }
    }

    pub fn writeParentCastFunctions(self: Class, gpa: std.mem.Allocator, data: TokenContainer, out: *std.Io.Writer) !void {
        // the first item is `self`
        const basesT = (try self.getBases(gpa, data))[0..];
        defer gpa.free(basesT);
        const bases = basesT[1..];

        for (bases) |base| {
            if (base.access != .public) continue;
            const baseClass = switch (data.find(base.type) orelse return DataSearch.MissingID) {
                .Class, .Struct => |v| v,
                else => unreachable,
            };

            const namespaced = try namespacedType(base.type, data, gpa) orelse return DataSearch.MissingID;
            defer gpa.free(namespaced);

            try out.print(
                \\pub inline fn @"castTo{s}"(self: *@This()) *{s} {{
                \\    const byte_ptr: usize = @intFromPtr(self);
                \\    const casted: *{s} = @ptrFromInt(byte_ptr + {d});
                \\    return casted;
                \\}}
                \\pub inline fn @"constCastTo{s}"(self: *const @This()) *const {s} {{
                \\    const byte_ptr: usize = @intFromPtr(self);
                \\    const casted: *const {s} = @ptrFromInt(byte_ptr + {d});
                \\    return casted;
                \\}}
            , .{
                baseClass.name,
                namespaced,
                namespaced,
                base.offset,
                baseClass.name,
                namespaced,
                namespaced,
                base.offset,
            });
        }
    }

    /// concats all bases into a slice, provides `self` as the first item
    /// returned memory is owned by caller.
    /// ignores private bases & methods
    pub fn getBases(self: Class, gpa: std.mem.Allocator, data: TokenContainer) ![]Base {
        var list = try std.ArrayList(Base).initCapacity(gpa, self.bases.len + 1);
        list.appendAssumeCapacity(.{ .type = self.id, .access = .public, .virtual = false, .offset = 0 });
        for (self.bases) |value| {
            if (value.access != .public) continue;
            const parent = switch (data.find(value.type) orelse return DataSearch.MissingID) {
                .Struct, .Class => |v| v,
                else => unreachable,
            };
            const more = try parent.getBases(gpa, data);
            defer gpa.free(more);
            for (more[1..]) |*item|
                // accounting for local offset
                item.offset += more[0].offset;

            try list.appendSlice(gpa, more);
        }
        return try list.toOwnedSlice(gpa);
    }

    /// Creates a classData for all of the inherited and builtin methods
    /// provides all methods
    pub fn compileMethods(self: Class, gpa: std.mem.Allocator, data: TokenContainer, ctx: Context) !Context.ClassData {
        const bases = try self.getBases(gpa, data);
        defer gpa.free(bases);

        var methods = std.array_hash_map.String(Method).empty;
        defer methods.deinit(gpa);
        for (bases) |baseVal| {
            const base = switch (data.find(baseVal.type) orelse return DataSearch.MissingID) {
                .Struct, .Class => |v| v,
                else => unreachable,
            };
            const classData = ctx.data.get(base.id) orelse return DataSearch.MissingID;
            var cit = classData.iterator();
            while (cit.next()) |arr| {
                for (arr.value_ptr.items) |id| {
                    const val = data.get(.Method).get(id) orelse unreachable;
                    try methods.put(gpa, id, val);
                }
            }
        }
        var i: usize = 0;
        while (i < methods.count()) {
            const item = &methods.values()[i];
            if (item.overrides) |ov| {
                const ovI = methods.getIndex(ov) orelse {
                    item.overrides = null;
                    continue;
                };
                if (ovI < i) {
                    item.overrides = methods.get(ov).?.overrides;
                } else {
                    // simple swap pop
                    item.overrides = (methods.get(ov) orelse return DataSearch.MissingID).overrides;
                    _ = methods.orderedRemove(ov);
                    i += 1;
                }
            } else i += 1;
        }
        try methods.reIndex(gpa);

        var ret = Context.ClassData.empty;
        try ret.ensureTotalCapacity(gpa, @truncate(methods.count()));
        for (methods.values()) |method| {
            const result = ret.getOrPut(gpa, method.name) catch unreachable;
            if (!result.found_existing) result.value_ptr.* = .empty;
            try result.value_ptr.append(gpa, method.id);
        }
        return ret;
    }

    pub fn concatMethods(self: Class, gpa: std.mem.Allocator, data: TokenContainer, ctx: Context) ![]Method {
        var methods = try self.compileMethods(gpa, data, ctx);
        defer methods.deinit(gpa);
        var sigma: usize = 0;
        {
            var i = methods.iterator();
            while (i.next()) |e|
                sigma += e.value_ptr.items.len;
        }
        var construction = try std.ArrayList(Method).initCapacity(gpa, sigma);
        {
            var i = methods.iterator();
            while (i.next()) |e| {
                for (e.value_ptr.items) |item| {
                    const value = data.get(.Method).get(item) orelse return DataSearch.MissingID;
                    construction.appendAssumeCapacity(value);
                }
                e.value_ptr.deinit(gpa);
            }
        }
        return construction.toOwnedSlice(gpa);
    }
};

pub const Struct = Class;

pub const FundamentalType = struct {
    id: []u8,
    name: []u8,
    size: u64,
    @"align": u64,

    pub const FundTypes = enum {
        float,
        int,
        bool,
        void,
    };
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, _: void, writer: *std.Io.Writer) !void {
        _ = gpa;
        _ = data;
        const t: FundTypes =
            if (std.mem.find(u8, self.name, "float") != null or std.mem.find(u8, self.name, "double") != null)
                .float
            else if (std.mem.eql(u8, self.name, "void"))
                .void
            else if (std.mem.eql(u8, self.name, "bool"))
                .bool
            else
                .int;

        switch (t) {
            .float => {
                try writer.print("const {s} = f{d};\n", .{
                    self.id,
                    self.size,
                });
            },
            .int => {
                const signed: std.builtin.Signedness = if (std.mem.find(u8, self.name, "unsigned") == null) .signed else .unsigned;

                const prefix: u8 = switch (signed) {
                    .signed => 'i',
                    .unsigned => 'u',
                };
                try writer.print("const {s} = {c}{d};\n", .{
                    self.id,
                    prefix,
                    self.size,
                });
            },
            inline .bool, .void => |v| {
                try writer.print("const {s} = " ++ @tagName(v) ++ ";\n", .{
                    self.id,
                });
            },
        }
    }
};

pub const Field = struct {
    id: []u8,
    name: []u8,
    type: []u8,
    // context: []u8,
    access: Access,
    offset: u64,
};

pub const Constructor = struct {
    id: []u8,
    context: []u8,
    access: Access,
    arguments: []Argument = &.{},
    @"inline": bool = false,

    /// user owns returned memory
    pub fn writeMangled(self: Constructor, constructorIndex: u64, gpa: std.mem.Allocator, data: TokenContainer) (error{ Inline, OutOfMemory } || std.Io.Writer.Error || DataSearch)![]u8 {
        if (self.@"inline") return error.Inline;

        const manglePrefix = "_Z";
        const rootNamespace = "::";

        var mangledName = std.Io.Writer.Allocating.init(gpa);
        defer mangledName.deinit();

        var parents: std.ArrayList([]const u8) = try .initCapacity(gpa, 1);
        defer parents.deinit(gpa);

        {
            var parent = self.context;
            while (data.find(parent)) |grandparent| {
                switch (grandparent) {
                    inline .Class, .Struct => |parentVal| {
                        parent = parentVal.context;
                        try parents.append(gpa, parentVal.name);
                    },
                    .Namespace => |namespace| {
                        parent = namespace.context orelse break;
                        try parents.append(gpa, namespace.name);
                    },
                    else => unreachable,
                }
            }
        }

        try mangledName.writer.print(manglePrefix, .{});
        if (parents.items.len >= 1) {
            try mangledName.writer.print("N", .{});
        }

        const ltEscape = "<";
        const gtEscape = ">";

        for (0..parents.items.len) |i| {
            const parent = parents.items[parents.items.len - 1 - i];
            if (std.mem.find(u8, parent, ltEscape)) |lt| lbl: {
                const gt = std.mem.find(u8, parent, gtEscape) orelse break :lbl;
                const templateType = parent[lt + ltEscape.len .. gt];
                const t = typeMap.get(templateType) orelse .{ templateType, .custom };
                switch (t.@"1") {
                    .custom => try mangledName.writer.print("I{d}{s}E", .{ t.@"0".len, t.@"0" }),
                    .primitive => try mangledName.writer.print("I{s}E", .{t.@"0"}),
                }
                continue;
            }
            if (std.mem.eql(u8, parent, rootNamespace)) continue;
            try mangledName.writer.print("{d}{s}", .{ parent.len, parent });
        }
        try mangledName.writer.print("C{d}E", .{constructorIndex + 1});
        const args = try writeMangledArguments(self.arguments, gpa, data);
        defer gpa.free(args);
        try mangledName.writer.print("{s}", .{args});
        return mangledName.toOwnedSlice();
    }
};

pub const Enumeration = struct {
    id: []u8,
    name: []u8,
    type: []u8,
    context: []u8,
    enumValues: []EnumValue = &.{},
    size: u64,
    @"align": u64,
    scoped: bool,
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, _: void, writer: *std.Io.Writer) !void {
        _ = gpa;
        _ = data;
        if (self.name.len == 0) return;
        try writer.print(
            \\const {s} = {s};
            \\pub const {s} = enum (u{d}) {{ 
            \\
        , .{
            self.name,
            self.id,
            self.id,
            self.size,
        });
        for (self.enumValues) |value| {
            try writer.print(
                \\{s} = {s},
                \\
            , .{ value.name, value.init });
        }
        try writer.print(
            \\_,
            \\}};
        , .{});
    }

    pub const EnumValue = struct {
        name: []u8,
        init: []u8,
    };
};

pub const PointerType = struct {
    id: []u8,
    type: []u8,
    size: u64 = 8,
    @"align": u64 = 8,
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, _: void, writer: *std.Io.Writer) !void {
        _ = gpa;
        _ = data;
        try writer.print("const {s} = ?*{s}; //ptr type\n", .{ self.id, self.type });
    }
};

pub const ReferenceType = struct {
    id: []u8,
    type: []u8,
    size: u64,
    @"align": u64,
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, _: void, writer: *std.Io.Writer) !void {
        const name = try namespacedType(self.type, data, gpa) orelse return;
        defer gpa.free(name);
        try writer.print("const {s} = *{s}; //ref type\n", .{ self.id, name });
    }
};

pub const RValueReferenceType = ReferenceType;

pub const Destructor = struct {
    id: []u8,
    context: []u8,
    access: Access,
    line: u64,
    @"inline": bool = false,
    virtual: bool = false,

    pub fn writeMangled(self: Destructor, gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) (error{ Inline, Virtual, OutOfMemory } || std.Io.Writer.Error)!void {
        if (self.@"inline") return error.Inline;
        if (self.virtual) return error.Virtual;

        const manglePrefix = "_Z";
        const totalSuffix = "D1Ev";

        var mangledName = std.Io.Writer.Allocating.init(gpa);
        defer mangledName.deinit();

        var parents: std.ArrayList([]const u8) = try .initCapacity(gpa, 1);
        defer parents.deinit(gpa);

        {
            var parent = self.context;
            while (data.find(parent)) |grandparent| {
                switch (grandparent) {
                    inline .Class, .Struct => |parentVal| {
                        parent = parentVal.context;
                        try parents.append(gpa, parentVal.name);
                    },
                    .Namespace => |namespace| {
                        parent = namespace.context orelse break;
                        try parents.append(gpa, namespace.name);
                    },
                    else => unreachable,
                }
            }
        }

        try mangledName.writer.print(manglePrefix, .{});
        if (parents.items.len >= 1)
            try mangledName.writer.print("N", .{});

        const ltEscape = "<";
        const gtEscape = ">";

        for (0..parents.items.len) |i| {
            const parent = parents.items[parents.items.len - 1 - i];
            if (std.mem.find(u8, parent, ltEscape)) |lt| lbl: {
                const gt = std.mem.find(u8, parent, gtEscape) orelse break :lbl;
                const templateType = parent[lt + ltEscape.len .. gt];
                const t = typeMap.get(templateType) orelse .{ templateType, .custom };
                switch (t.@"1") {
                    .custom => try mangledName.writer.print("I{d}{s}E", .{ t.@"0".len, t.@"0" }),
                    .primitive => try mangledName.writer.print("I{s}E", .{t.@"0"}),
                }
                continue;
            }
            if (std.mem.eql(u8, parent, Namespace.rootNamespace)) continue;
            try mangledName.writer.print("{d}{s}", .{ parent.len, parent });
        }
        try mangledName.writer.print(totalSuffix, .{});

        try writer.print("pub const deinit = @\"{s}\";\n", .{mangledName.writer.buffered()});
        try writer.print("extern \"c\" fn @\"{s}\"(*@This()) void;\n", .{mangledName.writer.buffered()});
    }
};

pub const Namespace = struct {
    id: []u8,
    name: []u8,
    context: ?[]u8 = null,

    pub const rootNamespaceId = "_1";
    pub const rootNamespace = "::";

    pub const Context = struct {
        data: ContextData,

        const ContextData = generateData();

        fn generateData() type {
            comptime {
                const values =
                    for (std.enums.values(@"type"), 0..) |v, i| {
                        if (v == .Namespace)
                            break std.enums.values(@"type")[0..i] ++ std.enums.values(@"type")[i + 1 ..];
                    };

                var names: [values.len][]const u8 = undefined;
                var types: [values.len]type = undefined;
                const attrs = &[1]std.builtin.Type.StructField.Attributes{
                    .{
                        .@"align" = null,
                        .@"comptime" = false,
                        .default_value_ptr = null,
                    },
                } ** values.len;

                for (values, 0..) |member, i| {
                    names[i] = @tagName(member);
                    const T = StructType(member);
                    if (@hasDecl(T, "Context")) {
                        if (@typeInfo(util.DeclType(T, "Context")) != .type)
                            @compileError("Context on " ++ @tagName(member) ++ " must be a `type`! is " ++ @typeName(util.DeclType(T, "Context")));
                        types[i] = @field(T, "Context");
                    } else {
                        types[i] = void;
                    }
                }

                return @Struct(.auto, null, &names, &types, attrs);
            }
        }

        pub fn init(gpa: std.mem.Allocator, data: TokenContainer) !Context {
            var ctx: Context = undefined;
            inline for (@typeInfo(Context.ContextData).@"struct".fields) |fieldInfo| {
                const FieldType = fieldInfo.type;
                switch (@typeInfo(FieldType)) {
                    .@"struct" => {
                        const InitType = util.DeclType(FieldType, "init");
                        if (InitType == FieldType) {
                            @field(ctx.data, fieldInfo.name) = @field(FieldType, "init");
                        } else {
                            switch (@typeInfo(InitType)) {
                                .@"fn" => |func| {
                                    if ((func.return_type orelse void) != FieldType // no point in calling
                                    and @typeInfo((func.return_type orelse void)) != .error_union and func.params.len > 2 // we only can supply 2
                                    )
                                        continue;
                                    const shouldCare: bool = inline for (func.params) |p| {
                                        if (p.type) |v| {
                                            if (v != TokenContainer and v != std.mem.Allocator) break false;
                                        }
                                    } else true;

                                    if (shouldCare) {
                                        const Args = std.meta.ArgsTuple(InitType);
                                        var a: Args = undefined;
                                        inline for (@typeInfo(InitType).@"fn".params, 0..) |p, i| {
                                            a[i] = switch (p.type orelse unreachable) {
                                                TokenContainer => data,
                                                std.mem.Allocator => gpa,
                                                else => unreachable,
                                            };
                                        }
                                        switch (@typeInfo(func.return_type orelse unreachable)) {
                                            .error_union => |err| {
                                                if (err.payload != FieldType)
                                                    continue
                                                else {
                                                    @field(ctx.data, fieldInfo.name) = try @call(.auto, @field(FieldType, "init"), a);
                                                    continue;
                                                }
                                            },
                                            else => void{},
                                        }
                                        @field(ctx.data, fieldInfo.name) = @call(.auto, @field(FieldType, "init"), a);
                                    }
                                },
                                else => void{},
                            }
                        }
                    },
                    else => void{},
                }
            }
            return ctx;
        }

        pub fn deinit(self: *Context, gpa: std.mem.Allocator) void {
            inline for (@typeInfo(@TypeOf(self.data)).@"struct".fields) |fieldInfo| {
                switch (@typeInfo(fieldInfo.type)) {
                    .@"struct" => {
                        if (@hasDecl(fieldInfo.type, "deinit")) {
                            const FnType = util.DeclType(fieldInfo.type, "deinit");
                            std.debug.assert(FnType == fn (fieldInfo.type, std.mem.Allocator) void //
                            or FnType == fn (*fieldInfo.type, std.mem.Allocator) void //
                            );
                            @field(self.data, fieldInfo.name).deinit(gpa);
                        }
                    },
                    else => continue,
                }
            }
        }
    };

    pub fn write(selfM: ?@This(), gpa: std.mem.Allocator, data: TokenContainer, ctx: Context, writer: *std.Io.Writer) !void {
        const members = comptime [_]@"type"{
            .ElaboratedType,
            .FundamentalType,
            .ArrayType,
            .CvQualifiedType,
            .PointerType,
            .ReferenceType,
            .Typedef,
            .Namespace,
            .Function,
            .Class,
            .Struct,
            .Enumeration,
        };

        const isroot =
            if (selfM) |self|
                std.mem.eql(u8, self.id, Namespace.rootNamespaceId)
            else
                false;

        if (selfM) |s|
            if (isroot)
                try writer.print("const {s} = @This();\n", .{s.id});

        if (!isroot)
            if (selfM) |self|
                try writer.print("const {s} = struct {{\n", .{self.id});

        inline for (members) |member| {
            const values = data.get(member);
            for (values.values()) |value| {
                const Member = StructType(member);
                if (!@hasField(Member, "context")) {
                    if (selfM == null) {
                        try value.write(gpa, data, @field(ctx.data, @tagName(member)), writer);
                    }
                    continue;
                }

                if (selfM) |self| {
                    const inSelf = switch (@typeInfo(@TypeOf(value.context))) {
                        .optional => std.mem.eql(u8, self.id, value.context orelse continue),
                        else => std.mem.eql(u8, self.id, value.context),
                    } and if (member == .Namespace) !std.mem.eql(u8, self.id, value.id) else true;

                    if (inSelf) {
                        if (member == .Namespace) {
                            try value.write(gpa, data, ctx, writer);
                        } else {
                            try value.write(gpa, data, @field(ctx.data, @tagName(member)), writer);
                        }
                    }
                } else {
                    const inSelf = switch (@typeInfo(@TypeOf(value.context))) {
                        .optional => value.context == null,
                        else => false,
                    };
                    if (inSelf) {
                        if (member == .Namespace) {
                            try value.write(gpa, data, ctx, writer);
                        } else {
                            try value.write(gpa, data, @field(ctx, @tagName(member)), writer);
                        }
                    }
                }
                try writer.flush();
            }
        }
        if (!isroot)
            if (selfM) |s| {
                try writer.print("}};\n", .{});
                try writer.print("pub const {s} = {s};\n", .{ s.name, s.id });
            };
    }
};

pub const Typedef = struct {
    id: []u8,
    name: []u8 = "",
    type: []u8,
    context: []u8,

    /// This Context is specifically for the following case
    /// ```cpp
    /// typedef struct {
    ///
    /// } MyStruct;
    /// ```
    pub const Context = struct {
        structures: std.hash_map.StringHashMapUnmanaged(void),

        pub fn init(gpa: std.mem.Allocator, data: TokenContainer) !Context {
            var set = std.hash_map.StringHashMapUnmanaged(void).empty;
            const members = [_]@"type"{ .Struct, .Class };
            inline for (members) |member|
                for (data.get(member).values()) |v|
                    try set.put(gpa, v.name, void{});
            return .{ .structures = set };
        }

        pub fn deinit(self: *Context, gpa: std.mem.Allocator) void {
            self.structures.deinit(gpa);
        }
    };

    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, ctx: Context, writer: *std.Io.Writer) !void {
        _ = .{ data, gpa };
        if (ctx.structures.get(self.name)) |_| {
            try writer.print(
                \\const {s} = {s};
                \\
            , .{ self.id, self.name });
        } else {
            try writer.print(
                \\pub const {s} = {s};
                \\const {s} = {s};
                \\
            , .{ self.name, self.type, self.id, self.name });
        }
    }
};

pub const ArrayType = struct {
    id: []u8,
    type: []u8,
    min: u64,
    max: ?u64 = null,
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, _: void, writer: *std.Io.Writer) !void {
        _ = gpa;
        _ = data;
        if (self.max) |m| {
            try writer.print("const {s} = ?[{d}]{s}; // arr type\n", .{
                self.id,
                m - self.min + 1,
                self.type,
            });
        } else {
            try writer.print("const {s} = ?[*]{s}; // arr type\n", .{
                self.id,
                self.type,
            });
        }
    }
};

pub const CvQualifiedType = struct {
    id: []u8,
    type: []u8,
    @"const": bool = false,
    @"volatile": bool = false,
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, _: void, writer: *std.Io.Writer) !void {
        const name = try namespacedType(self.type, data, gpa) orelse
            std.debug.panic("Error, {s} not found!\n", .{self.type});
        defer gpa.free(name);
        try writer.print("const {s} = {s}; // cv type\n", .{ self.id, name });
    }
};

pub const Function = struct {
    id: []u8,
    name: []u8,
    returns: []u8,
    context: []u8,
    mangled: []u8 = "",
    arguments: []Argument = &.{},
    @"inline": bool = false,
    artificial: bool = false,
    @"extern": bool = false,

    /// Used for context for the Function write function
    pub const Context = struct {
        data: std.hash_map.StringHashMap(std.ArrayList([]const u8)),

        pub fn init(data: TokenContainer, gpa: std.mem.Allocator) !Context {
            var self = std.hash_map.StringHashMap(std.ArrayList([]const u8)).init(gpa);
            for (data.get(.Function).values()) |*func| {
                if (!func.hasLabel()) continue;
                const value = try self.getOrPut(func.name);
                if (value.found_existing) {
                    try value.value_ptr.append(gpa, func.id);
                } else {
                    value.value_ptr.* = std.ArrayList([]const u8).empty;
                    try value.value_ptr.append(gpa, func.id);
                }
            }
            return .{ .data = self };
        }

        pub fn deinit(self: *Context, gpa: std.mem.Allocator) void {
            var it = self.data.valueIterator();
            while (it.next()) |v|
                v.deinit(gpa);
            self.data.deinit();
        }
    };

    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, ctx: Context, writer: *std.Io.Writer) !void {
        // anon function
        if (!self.hasLabel())
            return;

        const fns = ctx.data.get(self.name) orelse {
            std.log.debug("function named {s}", .{self.name});
            unreachable;
        };
        const overloaded: bool = fns.items.len > 1;

        if (overloaded)
            std.log.debug("function {s} {d} overloads", .{ self.name, fns.items.len });

        // if first overloaded item
        if (overloaded and std.mem.eql(u8, fns.items[0], self.id)) {
            try writer.print(
                \\pub const {s} = struct {{
                \\
            , .{self.name});
        }

        const externName = if (self.mangled.len == 0) self.name else self.mangled;
        const writeAlias = !std.mem.eql(u8, self.mangled, self.name) and self.mangled.len != 0;
        try writer.print(
            \\extern "c" fn @"{s}"(
        , .{externName});
        // for (self.arguments) |arg| {}
        for (self.arguments) |arg| {
            try writer.print(
                \\{s}, 
            , .{arg.type});
        }
        try writer.print(
            \\) callconv(.c) {s};
            \\
        , .{self.returns});

        const append = if (overloaded) try generateTypeSig(self, gpa, data) else "";
        defer gpa.free(append);

        if (writeAlias)
            try writer.print(
                \\pub const @"{s}{s}" = @"{s}";
                \\
            , .{ self.name, append, self.mangled });

        // if last overloaded item
        if (overloaded and std.mem.eql(u8, fns.getLast(), self.id)) {
            try writer.print(
                \\}};
                \\
            , .{});
        }
    }

    pub fn hasLabel(self: Function) bool {
        return self.name.len > 0 and !self.@"inline" and !self.@"extern";
    }
};

pub const Variable = struct {
    id: []u8,
    name: []u8,
    type: []u8,
    access: ?Access = null,
    static: bool,
    mangled: []u8 = "",
};

pub const ElaboratedType = struct {
    id: []u8,
    type: []u8,
    qualifier: ?[]u8 = null,
    keyword: ?KeywordType = null,

    const KeywordType = enum {
        class,
        @"struct",
        @"union",
        @"enum",
        typename,
    };

    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, _: void, writer: *std.Io.Writer) !void {
        _ = .{ gpa, data };
        try writer.print(
            \\const {s} = {s};
            \\
        , .{ self.id, self.type });
    }
};

pub const Union = struct {
    id: []u8,
    context: []u8,
    members: []u8 = "",
    name: []u8 = "",
    size: u64,
    @"align": u64,

    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, _: void, writer: *std.Io.Writer) !void {
        _ = gpa;
        _ = data;
        if (self.name.len == 0) return;
        try writer.print(
            \\const {s} = extern "c" union {{
            \\
        , .{self.id});
        var memberIterator = std.mem.splitScalar(u8, self.members, ' ');
        while (memberIterator.next()) |member| {
            try writer.print(
                \\{s},
                \\
            , .{member});
        }
        try writer.print(
            \\}} align ({d});
            \\
        , .{self.@"align"});
    }
};

pub const AtomicType = struct {
    id: []u8,
    type: []u8,
    size: u64,
    @"align": u64,
};

pub const FunctionType = struct {
    id: []u8,
    returns: []u8,
    arguments: []Argument = &.{},

    pub fn writeMangledTypeSig(
        self: FunctionType,
        gpa: std.mem.Allocator,
        data: TokenContainer,
    ) (DataSearch || std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
        var writer = std.Io.Writer.Allocating.init(gpa);
        errdefer writer.deinit();

        const args = try writeMangledArguments(self.arguments, gpa, data);
        defer gpa.free(args);
        try writer.writer.print(
            \\F{s}E
        , .{args});
        return writer.toOwnedSlice();
    }

    pub fn write(self: FunctionType, gpa: std.mem.Allocator, data: TokenContainer, out: *std.Io.Writer) !void {
        _ = .{ gpa, data };
        try out.print(
            \\const {s} = fn (
        , .{self.id});
        for (self.arguments) |arg| {
            try out.print(
                \\{s}, 
            , .{arg.type});
        }
        try out.print(
            \\) {s};
            \\
        , .{self.returns});
    }
};

pub const Argument = struct {
    // name: []u8,
    type: []u8,

    /// returned memory is owned by caller
    pub fn printName(self: Argument, gpa: std.mem.Allocator, data: TokenContainer) PrintError![]u8 {
        const fundType = try getUnderlyingType(self, data) orelse return PrintError.InvalidArgumentType;
        switch (fundType) {
            inline else => |val| {
                if (@hasField(@TypeOf(val), "name")) {
                    const found = typeMap.get(val.name);
                    if (found) |str| {
                        const retStr = try gpa.alloc(u8, str.@"0".len);
                        @memcpy(retStr, str.@"0");
                        return retStr;
                    } else {
                        const retStr = try gpa.alloc(u8, val.name.len);
                        @memcpy(retStr, val.name);
                        return retStr;
                    }
                } else if (@hasField(@TypeOf(val), "type")) {
                    const found = typeMap.get(val.type);
                    if (found) |str| {
                        const retStr = try gpa.alloc(u8, str.@"0".len);
                        @memcpy(retStr, str.@"0");
                        return retStr;
                    } else {
                        const retStr = try gpa.alloc(u8, val.type.len);
                        @memcpy(retStr, val.type);
                        return retStr;
                    }
                } else std.debug.panic("Error type {} has no field names `type` or `name`", .{@TypeOf(val)});
            },
        }
    }

    pub const PrintError = error{InvalidArgumentType} || DataSearch || std.mem.Allocator.Error;
};

pub fn setValue(
    T: type,
    m: *T,
    gpa: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
) error{ InvalidField, InvalidType, InvalidCharacter, Overflow, OutOfMemory }!void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            if (field.type == []u8 or field.type == []const u8) {
                const mem = try gpa.alloc(u8, value.len);
                @memcpy(mem, value);
                @field(m, field.name) = mem;
            } else switch (@typeInfo(field.type)) {
                .int => {
                    const val = try std.fmt.parseInt(field.type, value, 0);
                    @field(m, field.name) = val;
                },
                .float => {
                    const val = try std.fmt.parseFloat(field.type, value, 0);
                    @field(m, field.name) = val;
                },
                .@"enum" => |e| {
                    inline for (comptime std.enums.values(field.type)) |tag| {
                        if (std.mem.eql(u8, @tagName(tag), value)) {
                            @field(m, field.name) = tag;
                            break;
                        }
                    } else if (!e.is_exhaustive) @field(m, field.name) = try std.fmt.parseInt(e.tag_type, value, 0);
                },
                .bool => {
                    @field(m, field.name) = std.mem.eql(u8, "1", value);
                },
                .optional => |opt| {
                    if (value.len != 0) {
                        const Temporary = struct {
                            x: opt.child,
                        };
                        var t: Temporary = undefined;
                        try setValue(Temporary, &t, gpa, "x", value);
                        @field(m, field.name) = t.x;
                    } else @field(m, field.name) = null;
                },
                else => return,
            }
        }
    }
}

pub fn StructType(comptime t: @"type") type {
    return @field(@This(), @tagName(t));
}

pub fn getItem(str: []const u8) ?@"type" {
    inline for (std.enums.values(@"type")) |T|
        if (std.mem.eql(u8, str, @tagName(T)))
            return T;
    return null;
}

/// Writes the full namespaced type
/// Returns the outputted slice
pub fn namespacedType(id: []const u8, data: TokenContainer, gpa: std.mem.Allocator) !?[]const u8 {
    if (data.find(id)) |self| {
        switch (self) {
            inline else => |selfVal, selfTag| {
                const Type = StructType(selfTag);
                if (comptime @hasField(Type, "context")) {
                    if (@as(?[]const u8, selfVal.context)) |ctx| {
                        const parent = try namespacedType(ctx, data, gpa) orelse
                            return null;
                        defer gpa.free(parent);
                        return try std.mem.concat(
                            gpa,
                            u8,
                            &.{
                                parent,
                                ".",
                                selfVal.id,
                            },
                        );
                    } else return {
                        const mem = try gpa.alloc(u8, id.len);
                        @memcpy(mem, id);
                        return mem;
                    };
                } else {
                    const mem = try gpa.alloc(u8, id.len);
                    @memcpy(mem, id);
                    return mem;
                }
            },
        }
    } else return null;
}

/// Given a type, creates a `deinit` function for the type.
/// which can be called like such
/// ```zig
/// deinitToken(token.Class)(&myClass, gpa);
/// ```
pub fn deinitToken(comptime T: type) fn (*T, std.mem.Allocator) void {
    const fun = (struct {
        fn function(self: *T, gpa: std.mem.Allocator) void {
            switch (@typeInfo(T)) {
                .pointer => |ptr| {
                    switch (ptr.size) {
                        .slice => {
                            if (!util.isFundamental(ptr.child))
                                for (self.*) |*i|
                                    deinitToken(ptr.child)(i, gpa);
                            gpa.free(self.*);
                        },
                        .one => {
                            if (!util.isFundamental(ptr.child))
                                deinitToken(ptr.child)(&self.*);
                            gpa.destroy(self);
                        },
                        .many => {
                            if (!util.isFundamental(ptr.child))
                                for (self.*) |*v|
                                    deinitToken(ptr.child)(v, gpa);
                            gpa.free(self);
                        },
                        .c => {
                            if (!util.isFundamental(ptr.child))
                                deinitToken(ptr.child)(&self.*);
                            gpa.destroy(self);
                        },
                    }
                },
                .@"struct" => |str| {
                    if (@hasDecl(T, "deinit"))
                        self.deinit(gpa)
                    else inline for (str.fields) |field|
                        if (!util.isFundamental(field.type))
                            deinitToken(field.type)(&@field(self, field.name), gpa);
                },
                .optional => |opt| {
                    if (self.*) |*val|
                        if (!util.isFundamental(opt.child))
                            deinitToken(opt.child)(val, gpa);
                },
                .@"union" => {
                    switch (self.*) {
                        inline else => |*v| {
                            if (!util.isFundamental(@TypeOf(v.*)))
                                deinitToken(@TypeOf(v.*))(v, gpa);
                        },
                    }
                },
                .vector => |v| {
                    if (!util.isFundamental(@TypeOf(v.*)))
                        for (v) |*value|
                            deinitToken(v.child)(value, gpa);
                },
                else => {},
            }
        }
    }).function;
    return fun;
}

pub const TokenUnion: type = blk: {
    const types = std.enums.values(@"type");
    var typeNames: [types.len][]const u8 = undefined;
    var fieldTypes: [types.len]type = undefined;
    var fieldAttrs = [1]std.builtin.Type.UnionField.Attributes{.{ .@"align" = null }} ** types.len;
    for (types, 0..) |t, i| {
        typeNames[i] = @tagName(t);
        fieldTypes[i] = StructType(t);
    }
    break :blk @Union(.auto, @"type", &typeNames, &fieldTypes, &fieldAttrs);
};

/// Will only return union members
///     - `.Class`,
///     - `.Struct`,
///     - `.ArrayType`,
///     - `.CvQualifiedType`,
///     - `.FundamentalType`,
///     - `.PointerType`,
///     - `.ReferenceType`,
/// Only returns `null` if `@TypeOf(token) == token.ElaboratedType`
/// and lacks a valid type.
fn getUnderlyingType(token: anytype, data: TokenContainer) DataSearch!?TokenUnion {
    const T = @TypeOf(token);
    const basename = comptime util.getBaseName(T);

    switch (T) {
        Class,
        FundamentalType,
        ArrayType,
        PointerType,
        ReferenceType,
        Union,
        => return @unionInit(TokenUnion, basename, token),

        else => {
            if (comptime @hasField(T, "type")) {
                switch (data.find(token.type) orelse {
                    return DataSearch.MissingID;
                }) {
                    inline else => |value| return getUnderlyingType(value, data),
                }
            } else {
                return null;
            }
        },
    }
}

/// returns size in bytes, and alignment in bytes
fn getTypeSize(token: anytype, data: TokenContainer) DataSearch!?@Tuple(&.{ u64, u64 }) {
    const underlying = try getUnderlyingType(token, data) orelse return null;
    switch (underlying) {
        .ArrayType => |arr| {
            const underlyingInfo = switch (data.find(arr.type) orelse return DataSearch.MissingID) {
                inline else => |t| try getTypeSize(t, data) orelse unreachable,
            };
            if (arr.max) |m| {
                return .{
                    underlyingInfo.@"0" * (m - arr.min + 1),
                    underlyingInfo.@"1",
                };
            } else return .{
                0,
                underlyingInfo.@"1",
            };
        },
        else => void{},
    }

    const @"align" = switch (underlying) {
        inline .PointerType,
        .ReferenceType,
        .Class,
        .Struct,
        .FundamentalType,
        .Union,
        => |v| v.@"align",
        else => unreachable,
    };
    const size = switch (underlying) {
        inline .PointerType,
        .ReferenceType,
        .Class,
        .Struct,
        .FundamentalType,
        .Union,
        => |v| v.size / 8,
        else => unreachable,
    };
    return .{ size, @"align" };
}

pub const DataSearch = error{MissingID};

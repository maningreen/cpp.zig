const std = @import("std");
const debug = std.debug;
const TokenContainer = @import("container.zig");
const util = @import("util.zig");

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
};

pub const Method = struct {
    name: []u8,
    mangled: []u8 = "",
    id: []u8,
    returns: []u8,
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

    const vtableName = "_vtable";
    const vtableType = "Vtable";

    const Base = struct {
        type: []u8,
        access: Access,
        virtual: bool,
        offset: u64,
    };

    pub fn write(self: Class, gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !void {
        if (self.name.len == 0)
            // Ghost class
            return;

        if (self.incomplete) return;
        try writer.print(
            \\const @"{s}" = extern struct {{
            \\
        , .{self.id});

        var fields = std.ArrayList([]const u8).empty;
        defer fields.deinit(gpa);

        // 1 -> generate a vtable structure
        // 2 -> print fields
        // 3 -> print callables (and virtuals)

        // Stage 1 -> generate a vtable.
        try writer.print(
            \\const {s} = extern struct {{
            \\
        , .{vtableType});
        const virtualItems: bool = try writeVtableFields(self, gpa, data, writer);
        try writer.print(
            \\}};
            \\
        , .{});

        // Phase 2 -> print fields
        {
            if (virtualItems) {
                try writer.print("{s}: *const {s},\n", .{
                    vtableName,
                    vtableType,
                });
            }
            try self.writeFields(data, gpa, writer);
        }

        // Phase 3 -> print functions
        //
        // part 1: print constructors & destructors

        {
            var memberIterator = std.mem.splitScalar(u8, self.members, ' ');
            var initIterator: u64 = 0;
            while (memberIterator.next()) |member| {
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
            var memberIterator = std.mem.splitScalar(u8, self.members, ' ');
            while (memberIterator.next()) |memberID| {
                switch (data.find(memberID) orelse continue) {
                    .Method => |method| {
                        // inline methods have no labels, so we can't link
                        if (method.@"inline") continue;
                        if (method.access != .public) continue;
                        const prefix = if (method.@"const") "const " else "";
                        if (method.virtual) {
                            try writer.print(
                                \\pub fn {s}(self: *{s}@This(),
                            , .{ method.name, prefix });
                            for (method.arguments, 0..) |arg, i| {
                                try writer.print(
                                    \\arg{d}: {s}, 
                                , .{ i, arg.type });
                            }
                            try writer.print(
                                \\) {s} {{
                                \\    return self.{s}.{s}(self, 
                            , .{ method.returns, vtableName, method.name });
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
                    },
                    .Typedef => |td| {
                        const name = try namespacedType(td.type, data, gpa) orelse continue;
                        defer gpa.free(name);

                        try writer.print("pub const @\"{s}\" = {s};\n", .{ td.name, name });
                    },
                    else => continue,
                }
            }
        }

        try writer.print("}};\npub const @\"{s}\" = @\"{s}\";\n", .{ self.name, self.id });
    }

    /// prints out all of the fields of the class,
    /// and the inherited members
    /// does *not* print _vtable
    pub fn writeFields(self: Class, data: TokenContainer, gpa: std.mem.Allocator, writer: *std.Io.Writer) (DataSearch || std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        var memberIterator = std.mem.splitScalar(u8, self.members, ' ');
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
        while (memberIterator.next()) |memberid| {
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
                    try writer.print("{s}: {s},\n", .{ field.name, field.type });
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
    /// and an ample `data` structure, will lead to the following being written
    /// ```zig
    /// function: *const fn (void) void,
    /// ```
    /// returns whether or not it wrote anything, for a class without virtual members,
    /// simply returns false,
    pub fn writeVtableFields(self: Class, gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !bool {
        const items = try compileVirtual(self, gpa, data);
        defer gpa.free(items);

        if (items.len == 0)
            return false;

        for (items) |item| {
            switch (item) {
                .Destructor => {
                    try writer.print(
                        \\destruct: *const fn (*const @"{s}") callconv(.c) void,
                        \\delete: *const fn (*const @"{s}") callconv(.c) void,
                        \\
                    , .{ self.name, self.name });
                },
                .Method => |m| {
                    const constStr = if (m.@"const") "const" else "";

                    try writer.print(
                        \\@"{s}": *const fn (*{s} @"{s}",
                        \\
                    , .{
                        m.name,
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
    pub fn compileVirtual(self: Class, gpa: std.mem.Allocator, data: TokenContainer) ![]VirtualUnion {
        var arrList = std.ArrayList(VirtualUnion).empty;
        var memberIterator = std.mem.splitScalar(u8, self.members, ' ');
        while (memberIterator.next()) |member| {
            switch (data.find(member) orelse continue) {
                inline .Destructor, .Method => |v, t| if (v.virtual) try arrList.append(gpa, @unionInit(VirtualUnion, @tagName(t), v)),
                else => continue,
            }
        }

        if (arrList.items.len == 0) return try arrList.toOwnedSlice(gpa);

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
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !void {
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
        for (self.arguments) |arg| {
            var t: []const u8 = arg.type;
            while (true) {
                switch ((data.find(t) orelse return DataSearch.MissingID)) {
                    .FundamentalType => |fund| {
                        const value = typeMap.get(fund.name) orelse debug.panic("reached invalid type: {s}", .{fund.name});
                        try mangledName.writer.print("{s}", .{value.@"0"});
                        break;
                    },
                    inline .ArrayType, .PointerType => |ptr| {
                        try mangledName.writer.print("P", .{});
                        t = ptr.type;
                    },
                    .ReferenceType => |ref| {
                        try mangledName.writer.print("R", .{});
                        t = ref.type;
                    },
                    inline .Union, .Class, .Struct => |cplx| {
                        try mangledName.writer.print("{d}{s}", .{ cplx.name.len, cplx.name });
                        break;
                    },
                    .CvQualifiedType => |cv| {
                        try mangledName.writer.print("{s}", .{if (cv.@"const") "K" else ""});
                        t = cv.type;
                    },
                    inline .ElaboratedType, .Typedef => |td| {
                        t = td.type;
                    },
                    else => |_, tag| std.debug.panic("Reached invalid argument of type {s}", .{@tagName(tag)}),
                }
            }
        } else {
            // the only way to get here is if there're no arguments
            // we break from every other case
            try mangledName.writer.print(comptime typeMap.get("void").?.@"0", .{});
        }
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
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !void {
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
    size: u64,
    @"align": u64,
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !void {
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
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !void {
        const name = try namespacedType(self.type, data, gpa) orelse return;
        defer gpa.free(name);
        try writer.print("const {s} = *{s}; //ref type\n", .{ self.id, name });
    }
};

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

        try writer.print("pub const deinit = {s};\n", .{mangledName.writer.buffered()});
        try writer.print("extern \"c\" fn {s}(*@This()) void;\n", .{mangledName.writer.buffered()});
    }
};

pub const Namespace = struct {
    id: []u8,
    name: []u8,
    context: ?[]u8 = null,

    pub const rootNamespaceId = "_1";
    pub const rootNamespace = "::";

    pub fn write(selfM: ?@This(), gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !void {
        const members = comptime [_]@"type"{
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
                try writer.print("pub const {s} = struct {{\n", .{self.id});

        inline for (members) |member| {
            const values = data.get(member);
            for (values.values()) |value| {
                if (!@hasField(StructType(member), "context")) {
                    if (selfM == null) {
                        try value.write(gpa, data, writer);
                    }
                    continue;
                }

                if (selfM) |self| {
                    const inSelf = switch (@typeInfo(@TypeOf(value.context))) {
                        .optional => std.mem.eql(u8, self.id, value.context orelse continue),
                        else => std.mem.eql(u8, self.id, value.context),
                    } and if (member == .Namespace) !std.mem.eql(u8, self.id, value.id) else true;

                    if (inSelf) {
                        try value.write(gpa, data, writer);
                    }
                } else {
                    const inSelf = switch (@typeInfo(@TypeOf(value.context))) {
                        .optional => value.context == null,
                        else => false,
                    };
                    if (inSelf) {
                        try value.write(gpa, data, writer);
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
    name: []u8,
    type: []u8,
    context: []u8,

    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !void {
        _ = gpa;
        _ = data;
        _ = self;
        _ = writer;
    }
};

pub const ArrayType = struct {
    id: []u8,
    type: []u8,
    min: u64,
    max: ?u64,
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !void {
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
    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !void {
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

    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !void {
        _ = gpa;
        _ = data;
        // anon function
        if (self.name.len == 0 or self.@"inline")
            return;
        std.log.info("Printing function named \"{s}\"", .{self.name});
        const externName = if (self.mangled.len == 0) self.name else self.mangled;
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
        if (externName.ptr != self.name.ptr)
            try writer.print(
                \\pub const @"{s}" = @"{s}";
                \\
            , .{ self.name, self.mangled });
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
};

pub const Union = struct {
    id: []u8,
    context: []u8,
    name: []u8,
    members: []u8 = "",
    size: u64,
    @"align": u64,

    pub fn write(self: @This(), gpa: std.mem.Allocator, data: TokenContainer, writer: *std.Io.Writer) !void {
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

pub const Argument = struct {
    // name: []u8,
    type: []u8,
    pub fn printName(self: Argument, gpa: std.mem.Allocator) ![]u8 {
        _ = gpa;
        typeMap.get(self.type);
    }
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
                switch (data.find(token.type) orelse return DataSearch.MissingID) {
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
                    underlyingInfo[0] * (m - arr.min + 1),
                    underlyingInfo[1],
                };
            } else return .{
                0,
                underlyingInfo[1],
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
        else => |v| std.debug.panic("Underlying is type of {s}", .{@typeName(@TypeOf(v))}),
    };
    const size = switch (underlying) {
        inline .PointerType,
        .ReferenceType,
        .Class,
        .Struct,
        .FundamentalType,
        .Union,
        => |v| v.size / 8,
        else => |v| std.debug.panic("Underlying is type of {s}", .{@typeName(@TypeOf(v))}),
    };
    return .{ size, @"align" };
}

pub const DataSearch = error{MissingID};

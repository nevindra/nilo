//! Types and routes far bigger than any handler here declares, to hold one
//! claim: **nothing in this module runs a caller out of backwards branches**
//! ([ADR 126](../docs/adr/126-a-check-pays-for-its-own-branches.md)).
//!
//! A body of 200 fields, a query or a form of 150, a route of eight params
//! and an enum of 1,000 values are photon's shapes times five. Before each
//! walk over them raised a quota sized from what it walks, every one of
//! these stopped with "evaluation exceeded 1000 backwards branches" at a line
//! in nilo, which reads as a fault in the type. The types are made by
//! functions declared here, apart from the tests, so a test's own quota does
//! not pay for them and the tests call nothing that raises one.

const std = @import("std");
const app_mod = @import("app.zig");
const form_mod = @import("form.zig");
const nilo_testing = @import("testing.zig");
const typed = @import("typed.zig");

const App = app_mod.App;
const testing = std.testing;

/// `n` fields of one type, each defaulting to zero, with 40-character names.
/// A body, a query and a form are structs with nothing declared in them, so
/// they can be made here rather than written out.
fn Wide(comptime n: usize) type {
    @setEvalBranchQuota(1_000_000);
    const zero: u32 = 0;
    var names: [n][:0]const u8 = undefined;
    var types: [n]type = undefined;
    var attributes: [n]std.lang.Type.Struct.FieldAttributes = undefined;
    for (&names, &types, &attributes, 0..) |*name, *T, *attribute, i| {
        name.* = std.fmt.comptimePrint("a_field_with_a_long_descriptive_name_{d:0>4}", .{i});
        T.* = u32;
        attribute.* = .{ .default_value_ptr = &zero };
    }
    return @Struct(.auto, null, &names, &types, &attributes);
}

const WideBody = Wide(200);
const WideQuery = Wide(150);
const WideForm = Wide(150);

const first = "a_field_with_a_long_descriptive_name_0000";
const last_of_query = "a_field_with_a_long_descriptive_name_0149";

fn echo(body: WideBody) WideBody {
    return body;
}

fn search(params: typed.Query(WideQuery)) u32 {
    return @field(params.value, last_of_query);
}

fn submit(incoming: form_mod.Form(WideForm)) u32 {
    return @field(incoming.value, last_of_query);
}

const Eight = struct {
    param_a_with_a_long_descriptive_name: u32,
    param_b_with_a_long_descriptive_name: u32,
    param_c_with_a_long_descriptive_name: u32,
    param_d_with_a_long_descriptive_name: u32,
    param_e_with_a_long_descriptive_name: u32,
    param_f_with_a_long_descriptive_name: u32,
    param_g_with_a_long_descriptive_name: u32,
    param_h_with_a_long_descriptive_name: u32,
};

fn eight(p: typed.Path(Eight)) u32 {
    const v = p.value;
    return v.param_a_with_a_long_descriptive_name + v.param_b_with_a_long_descriptive_name +
        v.param_c_with_a_long_descriptive_name + v.param_d_with_a_long_descriptive_name +
        v.param_e_with_a_long_descriptive_name + v.param_f_with_a_long_descriptive_name +
        v.param_g_with_a_long_descriptive_name + v.param_h_with_a_long_descriptive_name;
}

fn deep(id: u32) u32 {
    return id;
}

/// A thousand values with 40-character names.
const Big = blk: {
    @setEvalBranchQuota(10_000_000);
    var names: [1000][:0]const u8 = undefined;
    var values: [1000]u16 = undefined;
    for (&names, &values, 0..) |*name, *value, i| {
        name.* = std.fmt.comptimePrint("an_enum_value_with_a_longish_name_{d:0>4}", .{i});
        value.* = i;
    }
    break :blk @Enum(u16, .exhaustive, &names, &values);
};

const Pick = struct { kind: Big = @fromBackingInt(@intCast(0)), other: ?Big = null };

fn pickByQuery(params: typed.Query(Pick)) Big {
    return params.value.kind;
}

fn pickByBody(body: Pick) Pick {
    return body;
}

fn answer(app: *App, client: *nilo_testing.Client, path: []const u8) !void {
    const got = try client.get(app, path);
    try testing.expectEqual(@as(u16, 200), got.status);
}

test "a body of 200 fields is read, written and described" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/body", echo);
    app.docs(.{ .title = "t", .version = "1" });

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    const posted = try client.post(&app, "/body", "{\"" ++ first ++ "\":7}");
    try testing.expectEqual(@as(u16, 200), posted.status);
    try answer(&app, &client, "/openapi.json");
}

test "a query of 150 fields is read with Query and described" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/query", search);
    app.docs(.{ .title = "t", .version = "1" });

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    try answer(&app, &client, "/query?" ++ last_of_query ++ "=5");
    try answer(&app, &client, "/openapi.json");
}

test "a form of 150 fields is read with Form and described" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/form", submit);
    app.docs(.{ .title = "t", .version = "1" });

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    const posted = try client.postWith(&app, "/form", "application/x-www-form-urlencoded", last_of_query ++ "=5");
    try testing.expectEqual(@as(u16, 200), posted.status);
    try answer(&app, &client, "/openapi.json");
}

test "a route of eight long param names and a path of sixteen segments are checked" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/:param_a_with_a_long_descriptive_name/:param_b_with_a_long_descriptive_name" ++
        "/:param_c_with_a_long_descriptive_name/:param_d_with_a_long_descriptive_name" ++
        "/:param_e_with_a_long_descriptive_name/:param_f_with_a_long_descriptive_name" ++
        "/:param_g_with_a_long_descriptive_name/:param_h_with_a_long_descriptive_name", eight);
    try app.get("/a_literal_segment_of_some_length_01/a_literal_segment_of_some_length_02" ++
        "/a_literal_segment_of_some_length_03/a_literal_segment_of_some_length_04" ++
        "/a_literal_segment_of_some_length_05/a_literal_segment_of_some_length_06" ++
        "/a_literal_segment_of_some_length_07/a_literal_segment_of_some_length_08" ++
        "/a_literal_segment_of_some_length_09/a_literal_segment_of_some_length_10" ++
        "/a_literal_segment_of_some_length_11/a_literal_segment_of_some_length_12" ++
        "/a_literal_segment_of_some_length_13/a_literal_segment_of_some_length_14" ++
        "/a_literal_segment_of_some_length_15/:id", deep);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    try answer(&app, &client, "/1/2/3/4/5/6/7/8");
}

test "an enum of 1,000 values is read from a query and a body, and listed in the 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/pick", pickByQuery);
    try app.post("/pick", pickByBody);
    app.docs(.{ .title = "t", .version = "1" });

    // The document lists every value, about 80 KB, past the default 64 KiB:
    // this test passed on the 200 of an answer cut short until that became
    // `error.ResponseTooLarge`.
    var client = try nilo_testing.Client.init(testing.allocator, .{ .response_bytes = 1 << 20 });
    defer client.deinit();
    try answer(&app, &client, "/pick?kind=an_enum_value_with_a_longish_name_0999");
    const posted = try client.post(&app, "/pick", "{\"kind\":\"an_enum_value_with_a_longish_name_0999\"}");
    try testing.expectEqual(@as(u16, 200), posted.status);
    try answer(&app, &client, "/openapi.json");

    // The refusal names the choices, which is the walk over every value.
    const refused = try client.get(&app, "/pick?kind=nope");
    try testing.expectEqual(@as(u16, 400), refused.status);
}

//! nilo_proto: a logs request of 20 records, each with four attributes,
//! decoded into plain structs and written back out, which is what a gRPC
//! method that receives a message and answers with one costs (ADR 245).
//!
//! The message is OTLP's logs shape, reduced to the fields a record has in
//! practice: nested messages, a oneof, repeated messages, strings, bytes and
//! fixed and varint numbers. It is built once in `init` by the module's own
//! encoder, so the bytes the decode reads are what it writes; the operation
//! then reads them, and writes the result into a buffer sized by
//! `encodedSize`, so the allocation count is the decoder's slab and the
//! encoder's one buffer.

const std = @import("std");
const proto = @import("nilo_proto");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

const AnyValue = struct {
    pub const wire = .{};
    value: ?Value = null,
    const Value = union(enum) {
        pub const wire = .{ .string_value = 1, .bool_value = 2, .int_value = 3, .double_value = 4 };
        string_value: []const u8,
        bool_value: bool,
        int_value: i64,
        double_value: f64,
    };
};

const KeyValue = struct {
    pub const wire = .{ .key = 1, .value = 2 };
    key: []const u8 = "",
    value: ?AnyValue = null,
};

const LogRecord = struct {
    pub const wire = .{
        .time_unix_nano = .{ 1, .fixed64 },
        .severity_number = 2,
        .severity_text = 3,
        .body = 5,
        .attributes = 6,
        .trace_id = .{ 9, .bytes },
        .span_id = .{ 10, .bytes },
    };
    time_unix_nano: u64 = 0,
    severity_number: i32 = 0,
    severity_text: []const u8 = "",
    body: ?AnyValue = null,
    attributes: []const KeyValue = &.{},
    trace_id: []const u8 = "",
    span_id: []const u8 = "",
};

const ScopeLogs = struct {
    pub const wire = .{ .log_records = 2 };
    log_records: []const LogRecord = &.{},
};

const Resource = struct {
    pub const wire = .{ .attributes = 1 };
    attributes: []const KeyValue = &.{},
};

const ResourceLogs = struct {
    pub const wire = .{ .resource = 1, .scope_logs = 2 };
    resource: ?Resource = null,
    scope_logs: []const ScopeLogs = &.{},
};

const Request = struct {
    pub const wire = .{ .resource_logs = 1 };
    resource_logs: []const ResourceLogs = &.{},
};

fn text(value: []const u8) KeyValue {
    return .{ .key = "http.route", .value = .{ .value = .{ .string_value = value } } };
}

const Program = struct {
    bytes: []u8,
    out: []u8,

    pub fn init(gpa: std.mem.Allocator) !Program {
        var records: [20]LogRecord = undefined;
        const attrs = [_]KeyValue{
            text("/users/:id"),
            .{ .key = "http.status_code", .value = .{ .value = .{ .int_value = 200 } } },
            .{ .key = "cache.hit", .value = .{ .value = .{ .bool_value = true } } },
            .{ .key = "duration.ms", .value = .{ .value = .{ .double_value = 12.5 } } },
        };
        for (&records, 0..) |*r, i| r.* = .{
            .time_unix_nano = 1_700_000_000_000_000_000 + i,
            .severity_number = 9,
            .severity_text = "INFO",
            .body = .{ .value = .{ .string_value = "request completed" } },
            .attributes = &attrs,
            .trace_id = &(@as([16]u8, @splat(0xab))),
            .span_id = &(@as([8]u8, @splat(0xcd))),
        };
        const req: Request = .{ .resource_logs = &.{.{
            .resource = .{ .attributes = &.{text("checkout")} },
            .scope_logs = &.{.{ .log_records = &records }},
        }} };
        const bytes = try proto.encode(Request, gpa, req);
        return .{ .bytes = bytes, .out = try gpa.alloc(u8, bytes.len) };
    }

    pub fn deinit(_: *Program) void {}

    pub fn op(self: *Program, scratch: std.mem.Allocator, _: usize) !void {
        var input: []const u8 = self.bytes;
        harness.keep(&input);
        const req = try proto.decode(Request, scratch, input);
        const written = try proto.encodeInto(Request, self.out, req);
        harness.keep(req.resource_logs.len);
        harness.keep(written.len);
    }
};

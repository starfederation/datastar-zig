// Datastar SDK validation harness.
//
// Runs a tiny HTTP server on `std.http.Server` (the 0.16 stdlib) that exposes
// the endpoints expected by the official Datastar test client:
//
//     https://github.com/starfederation/datastar/blob/main/sdk/tests/README.md
//
// Build with:  zig build validation-test
// Run with:    ./zig-out/bin/validation-test         (listens on :7331)
// Test with:   go run github.com/starfederation/datastar/sdk/tests/cmd/datastar-sdk-tests@latest
//
// All SSE payloads are built with the framework-agnostic transformer
// functions from this SDK — no bundled HTTP server, no extra abstractions.

const std = @import("std");
const datastar = @import("datastar");
const Io = std.Io;

const PORT = 7331;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const address = try Io.net.IpAddress.parseIp6("::", PORT);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.log.info("Datastar SDK validation harness listening on http://localhost:{}/", .{PORT});

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const conn = listener.accept(io) catch |err| {
            if (err == error.Canceled) return;
            std.log.warn("accept error: {}", .{err});
            continue;
        };
        try group.concurrent(io, handleConnection, .{ io, allocator, conn });
    }
}

fn handleConnection(io: Io, allocator: std.mem.Allocator, conn: Io.net.Stream) Io.Cancelable!void {
    defer conn.close(io);

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = conn.reader(io, &read_buffer);
    var writer = conn.writer(io, &write_buffer);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    while (true) {
        defer _ = arena.reset(.retain_capacity);

        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch break;

        handleRequest(arena.allocator(), &request) catch |err| {
            std.log.err("handler error: {}", .{err});
            request.respond("internal error", .{ .status = .internal_server_error }) catch break;
            break;
        };
    }
}

fn handleRequest(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

    if (std.mem.eql(u8, path, "/")) return index(request);
    if (std.mem.eql(u8, path, "/test")) return runTest(arena, request);
    try request.respond("not found", .{ .status = .not_found });
}

fn index(request: *std.http.Server.Request) !void {
    try request.respond(
        \\See https://github.com/starfederation/datastar/blob/develop/sdk/tests/README.md
        \\for instructions on running the official Datastar validator against this harness.
    , .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=UTF-8" },
        },
    });
}

// ----- Test input shape (matches the official validator) -----

const TestInput = struct {
    events: []TestEvent,
};

const TestEvent = struct {
    type: []const u8,
    eventId: ?[]const u8 = null,
    retryDuration: ?i64 = null,

    // patchElements options
    elements: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    selector: ?[]const u8 = null,
    useViewTransition: ?bool = null,
    namespace: ?[]const u8 = null,

    // patchSignals options
    signals: ?std.json.ArrayHashMap(std.json.Value) = null,
    @"signals-raw": ?[]const u8 = null,
    onlyIfMissing: ?bool = null,

    // executeScript options
    script: ?[]const u8 = null,
    attributes: ?TestEventAttribute = null,
    autoRemove: ?bool = null,
};

const TestEventAttribute = struct {
    type: []const u8,
    blocking: ?[]const u8 = null,
};

fn runTest(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    switch (request.head.method) {
        .GET, .POST => {},
        else => {
            try request.respond("invalid HTTP method", .{ .status = .bad_request });
            return;
        },
    }

    const input = datastar.readSignals(TestInput, arena, request) catch |err| {
        std.log.err("readSignals error: {}", .{err});
        try request.respond("invalid input", .{ .status = .bad_request });
        return;
    };

    if (input.events.len < 1) {
        try request.respond("empty events", .{ .status = .bad_request });
        return;
    }

    var body: Io.Writer.Allocating = .init(arena);

    for (input.events) |event| {
        if (std.mem.eql(u8, event.type, "patchElements")) {
            const mode: datastar.PatchMode = if (event.mode) |m|
                std.meta.stringToEnum(datastar.PatchMode, m) orelse {
                    try request.respond("invalid PatchElements mode", .{ .status = .bad_request });
                    return;
                }
            else
                .outer;

            const ns: datastar.NameSpace = if (event.namespace) |n|
                std.meta.stringToEnum(datastar.NameSpace, n) orelse {
                    try request.respond("invalid PatchElements namespace", .{ .status = .bad_request });
                    return;
                }
            else
                .html;

            const block = try datastar.patchElements(arena, event.elements orelse "", .{
                .mode = mode,
                .selector = event.selector,
                .view_transition = event.useViewTransition orelse false,
                .event_id = event.eventId,
                .retry_duration = event.retryDuration,
                .namespace = ns,
            });
            try body.writer.writeAll(block);
        } else if (std.mem.eql(u8, event.type, "patchSignals")) {
            const opts: datastar.PatchSignalsOptions = .{
                .only_if_missing = event.onlyIfMissing orelse false,
                .event_id = event.eventId,
                .retry_duration = event.retryDuration,
            };
            if (event.@"signals-raw") |raw| {
                try emitPatchSignalsRaw(&body.writer, raw, opts);
            } else if (event.signals) |signals| {
                const block = try datastar.patchSignals(arena, signals, opts);
                try body.writer.writeAll(block);
            }
        } else if (std.mem.eql(u8, event.type, "executeScript")) {
            const script = event.script orelse {
                try request.respond("executeScript missing the script param", .{ .status = .bad_request });
                return;
            };
            const block = try datastar.executeScript(arena, script, .{
                .auto_remove = event.autoRemove orelse true,
                .event_id = event.eventId,
                .retry_duration = event.retryDuration,
            });
            try body.writer.writeAll(block);
        }
    }

    try request.respond(body.written(), .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}

// The validator's `signals-raw` payload arrives as a multi-line JSON string
// (e.g. `{\n  "foo": 1\n}` in the JSON, which the parser unescapes into real
// `\n` bytes). The Datastar wire format needs every line of that JSON to be
// prefixed with `data: signals `. The SDK's typed `patchSignals` would
// re-serialize via `std.json.fmt` and collapse the whitespace, so we
// hand-build the SSE block for the raw-multiline case.
fn emitPatchSignalsRaw(w: *Io.Writer, raw: []const u8, opts: datastar.PatchSignalsOptions) !void {
    try w.writeAll("event: datastar-patch-signals\n");
    if (opts.event_id) |id| try w.print("id: {s}\n", .{id});
    if (opts.retry_duration) |r| try w.print("retry: {}\n", .{r});
    if (opts.only_if_missing) try w.writeAll("data: onlyIfMissing true\n");

    var line_in_progress = false;
    for (raw) |c| {
        if (c == '\n') {
            if (line_in_progress) {
                try w.writeAll("\n");
                line_in_progress = false;
            } else {
                try w.writeAll("data: signals \n");
            }
        } else {
            if (!line_in_progress) {
                try w.writeAll("data: signals ");
                line_in_progress = true;
            }
            try w.writeByte(c);
        }
    }
    if (line_in_progress) try w.writeAll("\n");
    try w.writeAll("\n");
}

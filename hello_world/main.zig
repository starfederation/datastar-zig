// hello_world.zig — minimal Datastar "Hello, world!" example.
//
// Zero dependencies outside the stdlib. Streams "Hello, world!"
// character-by-character over SSE with a configurable delay.
//
// Matches the official Go SDK hello-world example:
//   https://github.com/starfederation/datastar-go/tree/main/cmd/examples/helloworld
//
// Build:  zig build hello
// Run:    ./zig-out/bin/hello_world

const std = @import("std");
const datastar = @import("datastar");
const Io = std.Io;
const log = std.log;

const PORT = 8080;
const MESSAGE = "Hello, world!";

pub const std_options = std.Options{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const address = try Io.net.IpAddress.parseIp6("::", PORT);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    log.info("Datastar Hello World → http://localhost:{}/", .{PORT});

    while (true) {
        const conn = try listener.accept(io);
        group.concurrent(io, handleConnection, .{ io, allocator, conn }) catch |err| {
            log.err("spawn handler error: {}", .{err});
            conn.close(io);
            continue;
        };
    }
}

fn handleConnection(io: Io, allocator: std.mem.Allocator, conn: Io.net.Stream) Io.Cancelable!void {
    defer conn.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buffer);
    var writer = conn.writer(io, &write_buffer);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    while (true) {
        defer _ = arena.reset(.retain_capacity);

        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch break;

        handleRequest(io, arena.allocator(), &request) catch |err| {
            log.err("handler error: {}", .{err});
            _ = request.respond("internal error", .{ .status = .internal_server_error }) catch {};
            break;
        };
    }
}

fn handleRequest(io: Io, arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

    if (std.mem.eql(u8, path, "/")) return serveIndex(request);
    if (std.mem.eql(u8, path, "/hello-world")) return streamHello(io, arena, request);
    try request.respond("not found", .{ .status = .not_found });
}

fn serveIndex(request: *std.http.Server.Request) !void {
    try request.respond(@embedFile("hello_world.html"), .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=UTF-8" },
        },
    });
}

// streamHello using ultra-low-level vanilla stdlib code to do the streaming
// In a real development, you will more than likely want to use a proper web framework on top of vanilla stdlib
// ... but here is exactly all the low level steps you need to do SSE streaming correctly
fn streamHello(io: Io, arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const Signals = struct { delay_ms: i64 };
    const signals = datastar.readSignals(Signals, arena, request) catch Signals{ .delay_ms = 0 };
    log.info("Print Hello World with {}ms delay", .{signals.delay_ms});

    var body_buffer: [4096]u8 = undefined;
    var body = try request.respondStreaming(&body_buffer, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        },
    });
    defer body.end() catch {};
    try body.flush(); // push headers to the wire before first SSE event

    for (0..MESSAGE.len) |i| {
        const msg = MESSAGE[0 .. i + 1];
        const block = try datastar.patchElementsFmt(arena,
            \\<div id="message">{s}</div>
        , .{msg}, .{});
        std.debug.print("\r{s}\x1b[K", .{msg});
        try body.writer.writeAll(block);
        try body.writer.flush(); // drain body buffer → http_protocol_output
        try body.flush(); // flush http_protocol_output → wire
        if (signals.delay_ms > 0) {
            io.sleep(.fromMilliseconds(signals.delay_ms), .real) catch {};
        }
    }
    std.debug.print("\n", .{});
}

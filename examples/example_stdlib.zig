// example_stdlib.zig — kitchen-sink Datastar example, stdlib only.
//
// Build:  zig build stdlib
// Run:    ./zig-out/bin/example_stdlib

const std = @import("std");
const datastar = @import("datastar");
const Io = std.Io;

const PORT = 8081;

pub const std_options = std.Options{ .log_level = .debug };

var update_count: usize = 1;
var update_mutex: Io.Mutex = .init;

var prng: std.Random.DefaultPrng = .init(0);

var shared_io: Io = undefined;

fn getCountAndIncrement(io: Io) !usize {
    try update_mutex.lock(io);
    defer {
        update_count += 1;
        update_mutex.unlock(io);
    }
    return update_count;
}

var hotreload_id: u64 = 0;

fn setHotReload(io: Io) void {
    const ts = Io.Clock.now(.real, io);
    const seed_u96: u96 = @bitCast(ts.nanoseconds);
    prng.seed(@truncate(seed_u96));
    hotreload_id = prng.random().int(u64);
    std.log.debug("Hotreload ID {}", .{hotreload_id});
}

pub fn main(init: std.process.Init) !void {
    shared_io = init.io;
    setHotReload(init.io);

    const io = init.io;
    const allocator = init.gpa;

    const address = try Io.net.IpAddress.parseIp6("::", PORT);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    std.log.info("Datastar SDK stdlib example → http://localhost:{}/", .{PORT});

    while (true) {
        const conn = try listener.accept(io);
        group.concurrent(io, handleConnection, .{ io, allocator, conn }) catch |err| {
            std.log.err("spawn handler error: {}", .{err});
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

        handleRequest(arena.allocator(), &request) catch |err| {
            std.log.err("handler error: {}", .{err});
            _ = request.respond("internal error", .{ .status = .internal_server_error }) catch {};
            break;
        };
    }
}

// ----- Manual router -----

fn handleRequest(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;
    const method = request.head.method;

    // Split into segments: skip leading '/', collect parts.
    var segments: [8][]const u8 = undefined;
    var seg_count: usize = 0;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |seg| : (seg_count += 1) {
        if (seg_count < segments.len) segments[seg_count] = seg;
    }

    if (seg_count == 0 or std.mem.eql(u8, segments[0], "")) {
        return serveHtml(arena, request, @embedFile("index.html"), .{
            .hotreload_id = hotreload_id,
            .web_server = "Zig stdlib Server",
        });
    }

    if (std.mem.eql(u8, segments[0], "style.css") and seg_count == 1) {
        return request.respond(@embedFile("style.css"), .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/css; charset=UTF-8" }},
        });
    }

    if (std.mem.eql(u8, segments[0], "text-html") and seg_count == 1) {
        return textHtml(arena, request);
    }
    if (std.mem.eql(u8, segments[0], "patch") and seg_count == 1) {
        return patchElements(arena, request);
    }
    if (seg_count >= 2 and std.mem.eql(u8, segments[0], "patch")) {
        if (std.mem.eql(u8, segments[1], "opts")) {
            if (seg_count == 2) return patchElementsOpts(arena, request);
            if (seg_count == 3 and std.mem.eql(u8, segments[2], "reset")) return patchElementsOptsReset(arena, request);
        }
        if (std.mem.eql(u8, segments[1], "json") and seg_count == 2) return jsonSignals(arena, request);
        if (std.mem.eql(u8, segments[1], "signals")) {
            if (seg_count == 2) return patchSignals(arena, request);
            if (seg_count == 3 and std.mem.eql(u8, segments[2], "onlymissing")) return patchSignalsOnlyIfMissing(arena, request);
            if (seg_count == 4 and std.mem.eql(u8, segments[2], "remove")) return patchSignalsRemove(arena, request, segments[3]);
        }
    }
    if (seg_count == 2 and std.mem.eql(u8, segments[0], "executescript")) {
        const sample = std.fmt.parseInt(u8, segments[1], 10) catch 0;
        return executeScript(arena, request, sample);
    }
    if (std.mem.eql(u8, segments[0], "svg-morph") and seg_count == 1) return svgMorph(arena, request);
    if (std.mem.eql(u8, segments[0], "mathml-morph") and seg_count == 1) return mathMorph(arena, request);
    if (seg_count == 2 and std.mem.eql(u8, segments[0], "code")) {
        const snip = std.fmt.parseInt(u8, segments[1], 10) catch 1;
        return code(arena, request, snip);
    }
    if (seg_count == 2 and std.mem.eql(u8, segments[0], "mime")) return mimeTest(arena, request, segments[1]);
    if (seg_count == 2 and std.mem.eql(u8, segments[0], "hotreload")) {
        const id = std.fmt.parseInt(u64, segments[1], 10) catch 0;
        return hotreload(request, id);
    }

    _ = method;
    try request.respond("not found", .{ .status = .not_found });
}

// ----- Helpers -----

fn serveHtml(arena: std.mem.Allocator, request: *std.http.Server.Request, comptime tmpl: []const u8, args: anytype) !void {
    const body = try std.fmt.allocPrint(arena, tmpl, args);
    try request.respond(body, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=UTF-8" }},
    });
}

fn respondSse(arena: std.mem.Allocator, request: *std.http.Server.Request, body: []const u8) !void {
    _ = arena; // autofix
    try request.respond(body, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}

fn respondJson(arena: std.mem.Allocator, request: *std.http.Server.Request, value: anytype) !void {
    _ = arena; // autofix
    var buf: [4096]u8 = undefined;
    var body = try request.respondStreaming(&buf, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        },
    });
    defer body.end() catch {};
    const jf = std.json.fmt(value, .{});
    try jf.format(&body.writer);
}

// ----- Handlers -----

fn textHtml(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const body = try std.fmt.allocPrint(arena,
        \\<p id="text-html">This is update number {d}</p>
    , .{try getCountAndIncrement(shared_io)});
    try request.respond(body, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=UTF-8" }},
    });
}

fn patchElements(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const block = try datastar.patchElementsFmt(arena,
        \\<p id="mf-patch">This is update number {d}</p>
    , .{try getCountAndIncrement(shared_io)}, .{});
    try respondSse(arena, request, block);
}

fn patchElementsOpts(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const signals = try datastar.readSignals(struct { morph: []const u8 }, arena, request);
    if (signals.morph.len < 1) return;

    var patch_mode: datastar.PatchMode = .outer;
    inline for (std.meta.fields(datastar.PatchMode)) |f| {
        if (std.mem.eql(u8, f.name, signals.morph)) {
            patch_mode = @enumFromInt(f.value);
            break;
        }
    }
    if (patch_mode == .outer or patch_mode == .inner) return;

    const opts: datastar.PatchElementsOptions = .{ .selector = "#mf-patch-opts", .mode = patch_mode };
    const body = switch (patch_mode) {
        .replace => try datastar.patchElements(arena,
            \\<p id="mf-patch-opts" class="border-4 border-error">Complete Replacement of the OUTER HTML</p>
        , opts),
        else => try datastar.patchElementsFmt(arena,
            \\<p>This is update number {d}</p>
        , .{try getCountAndIncrement(shared_io)}, opts),
    };
    try respondSse(arena, request, body);
}

fn patchElementsOptsReset(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const body = try datastar.patchElements(arena, @embedFile("index_opts.html"), .{});
    try respondSse(arena, request, body);
}

fn jsonSignals(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);
    try respondJson(arena, request, .{ .fooj = foo, .barj = bar });
}

fn patchSignals(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const foo = prng.random().intRangeAtMost(u8, 0, 255);
    const bar = prng.random().intRangeAtMost(u8, 0, 255);
    const body = try datastar.patchSignals(arena, .{ .foo = foo, .bar = bar }, .{});
    try respondSse(arena, request, body);
}

fn patchSignalsOnlyIfMissing(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const foo = prng.random().intRangeAtMost(u8, 1, 100);
    const bar = prng.random().intRangeAtMost(u8, 1, 100);
    const signals_block = try datastar.patchSignals(arena, .{ .newfoo = foo, .newbar = bar }, .{ .only_if_missing = true });
    const script_block = try datastar.executeScript(arena, "console.log('Patched newfoo and newbar, but only if missing');", .{});
    const body = try std.mem.concat(arena, u8, &.{ signals_block, script_block });
    try respondSse(arena, request, body);
}

fn patchSignalsRemove(arena: std.mem.Allocator, request: *std.http.Server.Request, names: []const u8) !void {
    var json_buf: Io.Writer.Allocating = .init(arena);
    try json_buf.writer.writeAll("{");

    var it = std.mem.splitScalar(u8, names, ',');
    var first = true;
    while (it.next()) |name| {
        if (!first) try json_buf.writer.writeAll(",");
        try json_buf.writer.print("\"{s}\":null", .{name});
        first = false;
    }
    try json_buf.writer.writeAll("}");

    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        json_buf.written(),
        .{},
    );
    const body = try datastar.patchSignals(arena, parsed, .{});
    try respondSse(arena, request, body);
}

fn executeScript(arena: std.mem.Allocator, request: *std.http.Server.Request, sample: u8) !void {
    var attribs = datastar.ScriptAttributes.init(arena);
    try attribs.put("type", "text/javascript");
    try attribs.put("trace", "true");
    try attribs.put("aardvark", "should appear last, not first");

    const body = switch (sample) {
        1 => try datastar.executeScript(
            arena,
            "console.log('Running from executeScript() directly');",
            .{},
        ),
        2 => try datastar.executeScript(arena,
            \\console.log('Multiline Script, using executeScript with a built-up payload');
            \\parent = document.querySelector('#execute-script-page');
            \\console.log(parent.outerHTML);
        , .{ .attributes = attribs }),
        3 => try datastar.executeScriptFmt(
            arena,
            "console.log('Using formatted print {d}');",
            .{sample},
            .{},
        ),
        else => try datastar.executeScriptFmt(
            arena,
            "console.log('Unknown SampleID {d}');",
            .{sample},
            .{},
        ),
    };
    try respondSse(arena, request, body);
}

// ----- Long-lived streaming SSE -----

fn beginStream(request: *std.http.Server.Request) !std.http.BodyWriter {
    var buf: [4096]u8 = undefined;
    var body = try request.respondStreaming(&buf, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        },
    });
    try body.flush();
    return body;
}

fn svgMorph(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const opt = try datastar.readSignals(struct { svgMorph: usize = 1 }, arena, request);

    var body = try beginStream(request);
    defer body.end() catch {};

    var frame_buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&frame_buf);

    for (0..opt.svgMorph) |_| {
        try emitSvgFrame(&body, &fba,
            \\<circle id="svg-circle" cx="{}" cy="{}" r="{}" class="fill-red-500 transition-all duration-500" />
        , .{ prng.random().intRangeAtMost(u8, 10, 100), prng.random().intRangeAtMost(u8, 10, 100), prng.random().intRangeAtMost(u8, 10, 80) });
        try shared_io.sleep(.fromMilliseconds(100), .real);

        try emitSvgFrame(&body, &fba,
            \\<rect id="svg-square" x="{}" y="{}" width="{}" height="80" class="fill-green-500 transition-all duration-500" />
        , .{ prng.random().intRangeAtMost(u8, 10, 100), prng.random().intRangeAtMost(u8, 10, 100), prng.random().intRangeAtMost(u8, 10, 80) });
        try shared_io.sleep(.fromMilliseconds(100), .real);

        try emitSvgFrame(&body, &fba,
            \\<polygon id="svg-triangle" points="{},{} {},{} {},{}" class="fill-blue-500 transition-all duration-500" />
        , .{
            prng.random().intRangeAtMost(u16, 50, 300), prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300), prng.random().intRangeAtMost(u16, 50, 300),
            prng.random().intRangeAtMost(u16, 50, 300), prng.random().intRangeAtMost(u16, 50, 300),
        });
        try shared_io.sleep(.fromMilliseconds(100), .real);
    }
}

fn emitSvgFrame(body: *std.http.BodyWriter, fba: *std.heap.FixedBufferAllocator, comptime fmt: []const u8, args: anytype) !void {
    fba.reset();
    const block = try datastar.patchElementsFmt(fba.allocator(), fmt, args, .{ .namespace = .svg });
    try body.writer.writeAll(block);
    try body.writer.flush();
    try body.flush();
}

const mathMLs = [_][]const u8{
    @embedFile("snippets/math1.html"),  @embedFile("snippets/math2.html"),
    @embedFile("snippets/math3.html"),  @embedFile("snippets/math4.html"),
    @embedFile("snippets/math5.html"),  @embedFile("snippets/math6.html"),
    @embedFile("snippets/math7.html"),  @embedFile("snippets/math8.html"),
    @embedFile("snippets/math9.html"),  @embedFile("snippets/math10.html"),
    @embedFile("snippets/math11.html"),
};

fn mathMorph(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const opt = try datastar.readSignals(struct { mathmlMorph: usize = 1 }, arena, request);

    if (opt.mathmlMorph == 1) {
        const a = try datastar.patchElementsFmt(arena,
            \\<mn id="math-factor" class="text-red-500 font-bold">{}</mn>
        , .{prng.random().intRangeAtMost(u16, 2, 22)}, .{ .namespace = .mathml, .view_transition = true });
        const b = try datastar.patchSignals(arena, .{ .mathmlMorph = 1 }, .{});
        const body = try std.mem.concat(arena, u8, &.{ a, b });
        try respondSse(arena, request, body);
        return;
    }

    var stream = try beginStream(request);
    defer stream.end() catch {};

    var frame_buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&frame_buf);

    const delay_ms: u64 = switch (mathMLs.len - 3) {
        1, 2 => 2000,
        3 => 1600,
        4 => 1200,
        else => 200,
    };

    for (0..opt.mathmlMorph) |_| {
        fba.reset();
        const r = prng.random().intRangeAtMost(u8, 1, mathMLs.len);
        const block = try datastar.patchElements(fba.allocator(), mathMLs[r - 1], .{ .namespace = .mathml });
        try stream.writer.writeAll(block);
        try stream.writer.flush();
        try stream.flush();
        try shared_io.sleep(.fromMilliseconds(delay_ms), .real);
    }

    fba.reset();
    const reset_block = try datastar.patchSignals(fba.allocator(), .{ .mathmlMorph = 1 }, .{});
    try stream.writer.writeAll(reset_block);
    try stream.writer.flush();
    try stream.flush();
}

const snippets = [_][]const u8{
    @embedFile("snippets/code1.zig"),  @embedFile("snippets/code2.zig"),
    @embedFile("snippets/code3.zig"),  @embedFile("snippets/code4.zig"),
    @embedFile("snippets/code5.zig"),  @embedFile("snippets/code6.zig"),
    @embedFile("snippets/code7.zig"),  @embedFile("snippets/code8.zig"),
    @embedFile("snippets/code9.zig"),  @embedFile("snippets/code10.zig"),
    @embedFile("snippets/code11.zig"),
};

fn code(arena: std.mem.Allocator, request: *std.http.Server.Request, snip: u8) !void {
    if (snip < 1 or snip > snippets.len) return error.InvalidCodeSnippet;

    const data = snippets[snip - 1];
    var html: Io.Writer.Allocating = .init(arena);
    try html.writer.writeAll("<pre><code>");
    var line_it = std.mem.splitAny(u8, data, "\n");
    while (line_it.next()) |line| {
        try html.writer.writeAll("&nbsp;&nbsp;");
        for (line) |c| {
            switch (c) {
                '<' => try html.writer.writeAll("&lt;"),
                '>' => try html.writer.writeAll("&gt;"),
                ' ' => try html.writer.writeAll("&nbsp;"),
                else => try html.writer.writeByte(c),
            }
        }
        try html.writer.writeAll("\n");
    }
    try html.writer.writeAll("</code></pre>\n");

    const selector = try std.fmt.allocPrint(arena, "#code-{}", .{snip});
    const body = try datastar.patchElements(arena, html.written(), .{ .selector = selector, .mode = .append });
    try respondSse(arena, request, body);
}

fn mimeTest(arena: std.mem.Allocator, request: *std.http.Server.Request, filename: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "examples/assets/mime-tests/{s}", .{filename});
    const body = try Io.Dir.cwd().readFileAlloc(shared_io, path, arena, .limited(8 * 1024 * 1024));

    const ext = std.fs.path.extension(filename);
    const mime: []const u8 = if (std.mem.eql(u8, ext, ".css")) "text/css; charset=UTF-8" else if (std.mem.eql(u8, ext, ".js")) "application/javascript" else if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) "text/html; charset=UTF-8" else if (std.mem.eql(u8, ext, ".json")) "application/json" else "application/octet-stream";

    try request.respond(body, .{
        .extra_headers = &.{.{ .name = "content-type", .value = mime }},
    });
}

fn hotreload(request: *std.http.Server.Request, id: u64) !void {
    var stream = try beginStream(request);
    defer stream.end() catch {};

    var frame_buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&frame_buf);

    if (id != hotreload_id) {
        std.log.warn("Client is stale {} != {} - reload them", .{ id, hotreload_id });
        const block = try datastar.executeScript(fba.allocator(), "window.location.reload()", .{});
        try stream.writer.writeAll(block);
        try stream.writer.flush();
        try stream.flush();
        return;
    }

    var seconds: u64 = 0;
    while (true) {
        try shared_io.sleep(.fromMilliseconds(60_000), .real);
        seconds += 60;

        fba.reset();
        const ping = try std.fmt.allocPrint(fba.allocator(),
            \\<keepalive data-time="{}" />
        , .{seconds});
        const block = try datastar.patchElements(fba.allocator(), ping, .{});
        try stream.writer.writeAll(block);
        try stream.writer.flush();
        try stream.flush();
    }
}

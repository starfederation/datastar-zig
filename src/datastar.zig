const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Command = enum {
    patch_elements,
    patch_signals,
    execute_script,
};

pub const PatchMode = enum {
    inner,
    outer,
    replace,
    prepend,
    append,
    before,
    after,
    remove,
};

pub const NameSpace = enum {
    html,
    svg,
    mathml,
};

pub const PatchElementsOptions = struct {
    mode: PatchMode = .outer,
    selector: ?[]const u8 = null,
    view_transition: bool = false,
    view_transition_selector: ?[]const u8 = null,
    event_id: ?[]const u8 = null,
    retry_duration: ?i64 = null,
    namespace: NameSpace = .html,
};

pub const PatchSignalsOptions = struct {
    only_if_missing: bool = false,
    event_id: ?[]const u8 = null,
    retry_duration: ?i64 = null,
};

pub const ScriptAttributes = std.array_hash_map.String([]const u8);

pub const ExecuteScriptOptions = struct {
    /// by default remove the script after use, otherwise explicity set this to false if you want to keep the script loaded
    auto_remove: bool = true,
    attributes: ?ScriptAttributes = null,
    event_id: ?[]const u8 = null,
    retry_duration: ?i64 = null,
};

pub const default_buffer_size = 8 * 1024;

// Framework-agnostic transformer functions.
//
// Each one takes an arena allocator, a payload, and the relevant options struct,
// and returns a freshly-allocated string containing the SSE event-stream payload
// ready to be written verbatim into whatever response body your HTTP framework exposes.
//
// The arena owns the returned slice; free it by resetting/freeing the arena.

pub fn patchElements(arena: Allocator, elements: []const u8, opt: PatchElementsOptions) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    var msg_buffer: [default_buffer_size]u8 = undefined;
    var msg: Message = .patchElements(opt, &msg_buffer, &buf.writer);
    try msg.header();
    try msg.interface.writeAll(elements);
    try msg.end();
    return buf.written();
}

pub fn patchElementsFmt(arena: Allocator, comptime elements: []const u8, args: anytype, opt: PatchElementsOptions) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    var msg_buffer: [default_buffer_size]u8 = undefined;
    var msg: Message = .patchElements(opt, &msg_buffer, &buf.writer);
    try msg.header();
    try msg.interface.print(elements, args);
    try msg.end();
    return buf.written();
}

pub fn patchSignals(arena: Allocator, signals: anytype, opt: PatchSignalsOptions) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    var msg_buffer: [default_buffer_size]u8 = undefined;
    var msg: Message = .patchSignals(opt, &msg_buffer, &buf.writer);
    try msg.header();
    const json_formatter = std.json.fmt(signals, .{});
    try json_formatter.format(&msg.interface);
    try msg.end();
    return buf.written();
}

pub fn executeScript(arena: Allocator, script: []const u8, opt: ExecuteScriptOptions) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    var msg_buffer: [default_buffer_size]u8 = undefined;
    var msg: Message = .executeScript(opt, &msg_buffer, &buf.writer);
    try msg.header();
    try msg.interface.writeAll(script);
    try msg.end();
    return buf.written();
}

pub fn executeScriptFmt(arena: Allocator, comptime script: []const u8, args: anytype, opt: ExecuteScriptOptions) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    var msg_buffer: [default_buffer_size]u8 = undefined;
    var msg: Message = .executeScript(opt, &msg_buffer, &buf.writer);

    try msg.header();
    try msg.interface.print(script, args);
    try msg.end();
    return buf.written();
}

pub fn readSignals(comptime T: type, arena: std.mem.Allocator, req: *std.http.Server.Request) !T {
    switch (req.head.method) {
        .GET => {
            const target = req.head.target;
            const query_idx = std.mem.findScalar(u8, target, '?') orelse return error.MissingDatastarKey;
            const query_string = target[query_idx + 1 ..];

            var it = std.mem.tokenizeScalar(u8, query_string, '&');
            while (it.next()) |pair| {
                if (std.mem.startsWith(u8, pair, "datastar=")) {
                    const encoded_val = pair["datastar=".len..];
                    const decoded = try urlDecode(arena, encoded_val);

                    return std.json.parseFromSliceLeaky(
                        T,
                        arena,
                        decoded,
                        .{ .ignore_unknown_fields = true },
                    );
                }
            }
            return error.MissingDatastarKey;
        },
        else => {
            const length = req.head.content_length orelse return error.MissingContentLength;
            const body = try arena.alloc(u8, @intCast(length));

            var reader_buffer: [8192]u8 = undefined;
            const reader = req.readerExpectNone(&reader_buffer);

            try reader.readSliceAll(body);
            return std.json.parseFromSliceLeaky(
                T,
                arena,
                body,
                .{ .ignore_unknown_fields = true },
            );
        },
    }
}

const CommandOptions = union(Command) {
    patch_elements: PatchElementsOptions,
    patch_signals: PatchSignalsOptions,
    execute_script: ExecuteScriptOptions,
};

pub const Message = struct {
    /// buffer to write the expanded Datastar event stream to
    out_writer: *Io.Writer,
    started: bool,

    command: CommandOptions,

    line_in_progress: bool,
    interface: Io.Writer,

    pub fn patchElements(options: PatchElementsOptions, input_buffer: []u8, out_writer: *Io.Writer) Message {
        return .{
            .started = false,
            .line_in_progress = false,
            .out_writer = out_writer,
            .command = .{ .patch_elements = options },
            .interface = .{
                .buffer = input_buffer,
                .vtable = &.{
                    .drain = &drain,
                },
            },
        };
    }

    pub fn patchSignals(options: PatchSignalsOptions, input_buffer: []u8, out_writer: *Io.Writer) Message {
        return .{
            .started = false,
            .line_in_progress = false,
            .out_writer = out_writer,
            .command = .{ .patch_signals = options },
            .interface = .{
                .buffer = input_buffer,
                .vtable = &.{
                    .drain = &drain,
                },
            },
        };
    }

    pub fn executeScript(options: ExecuteScriptOptions, input_buffer: []u8, out_writer: *Io.Writer) Message {
        return .{
            .started = false,
            .line_in_progress = false,
            .out_writer = out_writer,
            .command = .{ .execute_script = options },
            .interface = .{
                .buffer = input_buffer,
                .vtable = &.{
                    .drain = &drain,
                },
            },
        };
    }

    pub fn swapTo(self: *Message, command: CommandOptions) !void {
        // can't always just swap to new command because it would swallow cancelation error.
        try self.end();
        self.command = command;
    }

    pub fn end(self: *Message) !void {
        var me = &self.interface;
        try me.flush();

        if (self.started) {
            self.started = false;
            self.line_in_progress = false;

            // const w = self.stream_writer;
            const w = self.out_writer;

            switch (self.command) {
                else => {},
                .execute_script => {
                    // need to close off the script tag !!
                    try w.writeAll("</script>");
                },
            }
            try w.writeAll("\n\n");
            try w.flush();
        }
    }

    pub fn header(self: *Message) !void {
        // var w = self.stream_writer;
        var w = self.out_writer;

        switch (self.command) {
            .patch_elements => |*patch_elements| {
                try w.writeAll("event: datastar-patch-elements\n");
                if (patch_elements.event_id) |event_id| {
                    try w.print("id: {s}\n", .{event_id});
                }
                if (patch_elements.retry_duration) |retry| {
                    try w.print("retry: {}\n", .{retry});
                }
                if (patch_elements.selector) |s| {
                    try w.print("data: selector {s}\n", .{s});
                }
                if (patch_elements.view_transition) {
                    try w.print("data: useViewTransition true\n", .{});
                }
                if (patch_elements.view_transition_selector) |s| {
                    try w.print("data: viewTransitionSelector {s}\n", .{s});
                }
                const mt = patch_elements.mode;
                switch (mt) {
                    .outer => {},
                    else => try w.print("data: mode {t}\n", .{mt}),
                }
                switch (patch_elements.namespace) {
                    .html => {},
                    .svg => try w.writeAll("data: namespace svg\n"),
                    .mathml => try w.writeAll("data: namespace mathml\n"),
                }
            },
            .patch_signals => |patch_signals| {
                try w.writeAll("event: datastar-patch-signals\n");
                if (patch_signals.event_id) |event_id| {
                    try w.print("id: {s}\n", .{event_id});
                }
                if (patch_signals.retry_duration) |retry| {
                    try w.print("retry: {}\n", .{retry});
                }
                if (patch_signals.only_if_missing) {
                    try w.writeAll("data: onlyIfMissing true\n");
                }
            },
            .execute_script => |execute_script| {
                try w.writeAll("event: datastar-patch-elements\n");
                if (execute_script.event_id) |event_id| {
                    try w.print("id: {s}\n", .{event_id});
                }
                if (execute_script.retry_duration) |retry| {
                    try w.print("retry: {}\n", .{retry});
                }
                try w.writeAll("data: mode append\ndata: selector body\ndata: elements <script");

                // now add the attribs if any are supplied
                if (execute_script.attributes) |attribs| {
                    for (attribs.keys(), attribs.values()) |key, value| {
                        try w.print(" {s}=\"{s}\"", .{ key, value });
                    }
                }
                if (execute_script.auto_remove) {
                    try w.writeAll(" data-effect=\"el.remove()\"");
                }

                try w.writeAll(">");
                self.line_in_progress = true; // because the script content is appended to the script declaration line !!
            },
        }
        self.started = true;
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        var self: *Message = @fieldParentPtr("interface", w);
        _ = splat;

        if (!self.started) {
            try self.header();
        }

        var written: usize = 0;

        if (w.end > 0) {
            written += try writeBytesScan(self, self.out_writer, w.buffered());
        }
        written += try writeBytesScan(self, self.out_writer, data[0]);

        // TODO - we have the expanded contents in self.out_buffer here - debug that, then send the whole contents of the out_buffer to the self.stream_writer
        return w.consume(written);
    }

    // implementation of writeBytes using SIMD scan of the input to find newlines
    fn writeBytesScan(self: *Message, stream_writer: *Io.Writer, bytes: []const u8) !usize {
        const prefix = switch (self.command) {
            .patch_elements, .execute_script => "data: elements ",
            .patch_signals => "data: signals ",
        };

        var rest = bytes;

        while (std.mem.findScalar(u8, rest, '\n')) |idx| {
            const line = rest[0 .. idx + 1];

            // Start a line if we aren't already in one
            if (!self.line_in_progress) {
                try stream_writer.writeAll(prefix);
            }
            try stream_writer.writeAll(line); // includes \n
            self.line_in_progress = false;

            // Advance past the newline, if there is more
            rest = rest[idx + 1 ..];
        }

        if (rest.len > 0) {
            if (!self.line_in_progress) {
                try stream_writer.writeAll(prefix);
                self.line_in_progress = true;
            }
            try stream_writer.writeAll(rest);
        }

        return bytes.len;
    }
};

pub fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, input.len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            out[j] = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch input[i];
            i += 3;
        } else if (input[i] == '+') {
            out[j] = ' ';
            i += 1;
        } else {
            out[j] = input[i];
            i += 1;
        }
        j += 1;
    }
    return out[0..j];
}

test "PatchElementsOptions default values" {
    const opts = PatchElementsOptions{};
    try std.testing.expectEqual(PatchMode.outer, opts.mode);
    try std.testing.expect(opts.selector == null);
    try std.testing.expect(opts.view_transition == false);
    try std.testing.expect(opts.event_id == null);
    try std.testing.expect(opts.retry_duration == null);
    try std.testing.expectEqual(NameSpace.html, opts.namespace);
}

test "PatchSignalsOptions default values" {
    const opts = PatchSignalsOptions{};
    try std.testing.expect(opts.only_if_missing == false);
    try std.testing.expect(opts.event_id == null);
    try std.testing.expect(opts.retry_duration == null);
}

test "ExecuteScriptOptions default values" {
    const opts = ExecuteScriptOptions{};
    try std.testing.expect(opts.auto_remove == true);
    try std.testing.expect(opts.attributes == null);
    try std.testing.expect(opts.event_id == null);
    try std.testing.expect(opts.retry_duration == null);
}

test "PatchMode enum values" {
    const modes = [_]PatchMode{
        .inner,
        .outer,
        .replace,
        .prepend,
        .append,
        .before,
        .after,
        .remove,
    };

    // Just verify all modes are distinct
    for (modes, 0..) |mode1, i| {
        for (modes[i + 1 ..]) |mode2| {
            try std.testing.expect(mode1 != mode2);
        }
    }
}

test "NameSpace enum values" {
    try std.testing.expectEqual(NameSpace.html, NameSpace.html);
    try std.testing.expectEqual(NameSpace.svg, NameSpace.svg);
    try std.testing.expectEqual(NameSpace.mathml, NameSpace.mathml);

    try std.testing.expect(NameSpace.html != NameSpace.svg);
    try std.testing.expect(NameSpace.svg != NameSpace.mathml);
}

test "Message.init sets correct command and options for patchElements" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var msg_buffer: [default_buffer_size]u8 = undefined;
    const msg: Message = .patchElements(.{ .mode = .inner, .selector = "#test" }, &msg_buffer, &writer);

    try std.testing.expectEqual(PatchMode.inner, msg.command.patch_elements.mode);
    try std.testing.expectEqualStrings("#test", msg.command.patch_elements.selector.?);
}

test "Message.init sets correct command and options for patchSignals" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var msg_buffer: [default_buffer_size]u8 = undefined;
    const msg: Message = .patchSignals(.{ .only_if_missing = true }, &msg_buffer, &writer);

    try std.testing.expect(msg.command.patch_signals.only_if_missing);
}

test "Message.init sets correct command and options for executeScript" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var msg_buffer: [default_buffer_size]u8 = undefined;
    const msg: Message = .executeScript(.{ .auto_remove = false }, &msg_buffer, &writer);

    try std.testing.expect(!msg.command.execute_script.auto_remove);
}

test "patchElements transformer emits SSE event stream" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try patchElements(arena, "<div id='hello'>Hi</div>", .{});
    try std.testing.expectEqualStrings(
        "event: datastar-patch-elements\ndata: elements <div id='hello'>Hi</div>\n\n",
        out,
    );
}

test "patchElements transformer honours options" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try patchElements(arena, "<p>x</p>", .{
        .mode = .inner,
        .selector = "#main",
        .view_transition = true,
        .event_id = "evt-1",
        .namespace = .svg,
    });
    try std.testing.expectEqualStrings(
        "event: datastar-patch-elements\nid: evt-1\ndata: selector #main\ndata: useViewTransition true\ndata: mode inner\ndata: namespace svg\ndata: elements <p>x</p>\n\n",
        out,
    );
}

test "patchElements transformer prefixes each line of multiline input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try patchElements(arena, "<div>\n  <p>hi</p>\n</div>", .{});
    try std.testing.expectEqualStrings(
        "event: datastar-patch-elements\ndata: elements <div>\ndata: elements   <p>hi</p>\ndata: elements </div>\n\n",
        out,
    );
}

test "patchElementsFmt transformer formats payload" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try patchElementsFmt(arena, "<p id='c'>count {d}</p>", .{42}, .{});
    try std.testing.expectEqualStrings(
        "event: datastar-patch-elements\ndata: elements <p id='c'>count 42</p>\n\n",
        out,
    );
}

test "patchSignals transformer emits JSON payload" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try patchSignals(arena, .{ .foo = 42, .bar = "baz" }, .{});
    try std.testing.expectEqualStrings(
        "event: datastar-patch-signals\ndata: signals {\"foo\":42,\"bar\":\"baz\"}\n\n",
        out,
    );
}

test "patchSignals transformer honours only_if_missing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try patchSignals(arena, .{ .x = 1 }, .{ .only_if_missing = true });
    try std.testing.expectEqualStrings(
        "event: datastar-patch-signals\ndata: onlyIfMissing true\ndata: signals {\"x\":1}\n\n",
        out,
    );
}

test "executeScript transformer wraps payload in a script tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try executeScript(arena, "console.log('hi')", .{});
    try std.testing.expectEqualStrings(
        "event: datastar-patch-elements\ndata: mode append\ndata: selector body\ndata: elements <script data-effect=\"el.remove()\">console.log('hi')</script>\n\n",
        out,
    );
}

test "executeScriptFmt transformer formats payload" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try executeScriptFmt(arena, "alert('hi {s}')", .{"world"}, .{ .auto_remove = false });
    try std.testing.expectEqualStrings(
        "event: datastar-patch-elements\ndata: mode append\ndata: selector body\ndata: elements <script>alert('hi world')</script>\n\n",
        out,
    );
}

test "PatchElementsOptions with custom values" {
    const opts = PatchElementsOptions{
        .mode = .inner,
        .selector = "#content",
        .view_transition = true,
        .event_id = "evt-123",
        .retry_duration = 5000,
        .namespace = .svg,
    };

    try std.testing.expectEqual(PatchMode.inner, opts.mode);
    try std.testing.expectEqualStrings("#content", opts.selector.?);
    try std.testing.expect(opts.view_transition);
    try std.testing.expectEqualStrings("evt-123", opts.event_id.?);
    try std.testing.expectEqual(5000, opts.retry_duration.?);
    try std.testing.expectEqual(NameSpace.svg, opts.namespace);
}

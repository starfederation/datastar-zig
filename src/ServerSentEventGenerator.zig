const std = @import("std");
const consts = @import("consts.zig");
const ArrayList = std.ArrayListUnmanaged;

const default_execute_script_attributes: []const []const u8 = &[_][]const u8{consts.default_execute_script_attributes};

allocator: std.mem.Allocator,
writer: std.net.Stream.Writer,

pub const ExecuteScriptOptions = struct {
    /// `event_id` can be used by the backend to replay events.
    /// This is part of the SSE spec and is used to tell the browser how to handle the event.
    /// For more details see https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#id
    event_id: ?[]const u8 = null,
    /// `retry_duration` is part of the SSE spec and is used to tell the browser how long to wait before reconnecting if the connection is lost.
    /// For more details see https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#retry
    retry_duration: u32 = consts.default_sse_retry_duration,
    /// A list of attributes to add to the script element.
    /// Each item in the array ***must*** be a string in the format `key value`.
    attributes: []const []const u8 = default_execute_script_attributes,
    /// Whether to remove the script after execution.
    auto_remove: bool = consts.default_execute_script_auto_remove,
};

pub const MergeFragmentsOptions = struct {
    /// `event_id` can be used by the backend to replay events.
    /// This is part of the SSE spec and is used to tell the browser how to handle the event.
    /// For more details see https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#id
    event_id: ?[]const u8 = null,
    /// `retry_duration` is part of the SSE spec and is used to tell the browser how long to wait before reconnecting if the connection is lost.
    /// For more details see https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#retry
    retry_duration: u32 = consts.default_sse_retry_duration,
    /// The CSS selector to use to insert the fragments.
    selector: ?[]const u8 = null,
    /// The mode to use when merging the fragment into the DOM.
    merge_mode: consts.FragmentMergeMode = consts.default_fragment_merge_mode,
    /// Whether to use view transitions.
    use_view_transition: bool = consts.default_fragments_use_view_transitions,
};

pub const MergeSignalsOptions = struct {
    /// `event_id` can be used by the backend to replay events.
    /// This is part of the SSE spec and is used to tell the browser how to handle the event.
    /// For more details see https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#id
    event_id: ?[]const u8 = null,
    /// `retry_duration` is part of the SSE spec and is used to tell the browser how long to wait before reconnecting if the connection is lost.
    /// For more details see https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#retry
    retry_duration: u32 = consts.default_sse_retry_duration,
    /// Whether to merge the signal only if it does not already exist.
    only_if_missing: bool = consts.default_merge_signals_only_if_missing,
};

pub const RemoveFragmentsOptions = struct {
    /// `event_id` can be used by the backend to replay events.
    /// This is part of the SSE spec and is used to tell the browser how to handle the event.
    /// For more details see https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#id
    event_id: ?[]const u8 = null,
    /// `retry_duration` is part of the SSE spec and is used to tell the browser how long to wait before reconnecting if the connection is lost.
    /// For more details see https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#retry
    retry_duration: u32 = consts.default_sse_retry_duration,
    /// Whether to use view transitions.
    use_view_transition: bool = consts.default_fragments_use_view_transitions,
};

pub const RemoveSignalsOptions = struct {
    /// `event_id` can be used by the backend to replay events.
    /// This is part of the SSE spec and is used to tell the browser how to handle the event.
    /// For more details see https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#id
    event_id: ?[]const u8 = null,
    /// `retry_duration` is part of the SSE spec and is used to tell the browser how long to wait before reconnecting if the connection is lost.
    /// For more details see https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#retry
    retry_duration: u32 = consts.default_sse_retry_duration,
};

fn send(
    self: *@This(),
    event: consts.EventType,
    data: []const u8,
    options: struct {
        event_id: ?[]const u8 = null,
        retry_duration: u32 = consts.default_sse_retry_duration,
    },
) !void {
    try self.writer.print("event: {}\n", .{event});

    if (options.event_id) |id| {
        try self.writer.print("id: {s}\n", .{id});
    }

    if (options.retry_duration != consts.default_sse_retry_duration) {
        try self.writer.print("retry: {d}\n", .{options.retry_duration});
    }

    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        try self.writer.print("data: {s}\n", .{line});
    }

    try self.writer.writeAll("\n\n");
}

/// `executeScript` executes JavaScript in the browser
///
/// See the [Datastar documentation](https://data-star.dev/reference/sse_events#datastar-execute-script) for more information.
pub fn executeScript(
    self: *@This(),
    /// `script` is a string that represents the JavaScript to be executed by the browser.
    script: []const u8,
    options: ExecuteScriptOptions,
) !void {
    var data = ArrayList(u8).empty;
    errdefer data.deinit(self.allocator);
    const writer = data.writer();

    if (options.attributes.len != 1 or !std.mem.eql(
        u8,
        default_execute_script_attributes[0],
        options.attributes[0],
    )) {
        for (options.attributes) |attribute| {
            try writer.print(
                consts.attributes_dataline_literal ++ " {s}\n",
                .{
                    attribute,
                },
            );
        }
    }

    if (options.auto_remove != consts.default_execute_script_auto_remove) {
        try writer.print(
            consts.auto_remove_dataline_literal ++ " {}\n",
            .{
                options.auto_remove,
            },
        );
    }

    var iter = std.mem.splitScalar(u8, script, '\n');
    while (iter.next()) |elem| {
        try writer.print(
            consts.script_dataline_literal ++ " {s}\n",
            .{
                elem,
            },
        );
    }

    try self.send(
        .execute_script,
        try data.toOwnedSlice(),
        .{
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );
}

/// `mergeFragments` merges one or more fragments into the DOM. By default,
/// Datastar merges fragments using Idiomorph, which matches top level elements based on their ID.
///
/// See the [Datastar documentation](https://data-star.dev/reference/sse_events#datastar-merge-fragments) for more information.
pub fn mergeFragments(
    self: *@This(),
    /// The HTML fragments to merge into the DOM.
    fragments: []const u8,
    options: MergeFragmentsOptions,
) !void {
    var data = ArrayList(u8).empty;
    errdefer data.deinit(self.allocator);
    const writer = data.writer();

    if (options.selector) |selector| {
        try writer.print(
            consts.selector_dataline_literal ++ " {s}\n",
            .{
                selector,
            },
        );
    }

    if (options.merge_mode != consts.default_fragment_merge_mode) {
        try writer.print(
            consts.merge_mode_dataline_literal ++ " {}\n",
            .{
                options.merge_mode,
            },
        );
    }

    if (options.use_view_transition != consts.default_fragments_use_view_transitions) {
        try writer.print(
            consts.use_view_transition_dataline_literal ++ " {}\n",
            .{
                options.use_view_transition,
            },
        );
    }

    var iter = std.mem.splitScalar(u8, fragments, '\n');
    while (iter.next()) |elem| {
        try writer.print(
            consts.fragments_dataline_literal ++ " {s}\n",
            .{
                elem,
            },
        );
    }

    try self.send(
        .merge_fragments,
        try data.toOwnedSlice(),
        .{
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );
}

/// `mergeSignals` sends one or more signals to the browser to be merged into the signals.
/// This function takes in `anytype` as the signals to merge, which can be any type that can be serialized to JSON.
///
/// See the [Datastar documentation](https://data-star.dev/reference/sse_events#datastar-merge-signals) for more information.
pub fn mergeSignals(
    self: *@This(),
    signals: anytype,
    options: MergeSignalsOptions,
) !void {
    var data = ArrayList(u8).empty;
    errdefer data.deinit(self.allocator);
    const writer = data.writer();

    if (options.only_if_missing != consts.default_merge_signals_only_if_missing) {
        try writer.print(
            consts.only_if_missing_dataline_literal ++ " {}\n",
            .{
                options.only_if_missing,
            },
        );
    }

    try writer.writeAll(consts.signals_dataline_literal ++ " ");
    try std.json.stringify(signals, .{}, writer);
    try writer.writeByte('\n');

    try self.send(
        .merge_signals,
        try data.toOwnedSlice(),
        .{
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );
}

/// `removeFragments` sends a selector to the browser to remove HTML fragments from the DOM.
///
/// See the [Datastar documentation](https://data-star.dev/reference/sse_events#datastar-remove-fragments) for more information.
pub fn removeFragments(
    self: *@This(),
    selector: []const u8,
    options: RemoveFragmentsOptions,
) !void {
    var data = ArrayList(u8).empty;
    errdefer data.deinit(self.allocator);
    const writer = data.writer();

    if (options.use_view_transition != consts.default_fragments_use_view_transitions) {
        try writer.print(
            consts.use_view_transition_dataline_literal ++ " {}\n",
            .{
                options.use_view_transition,
            },
        );
    }

    try writer.print(
        consts.selector_dataline_literal ++ " {s}\n",
        .{
            selector,
        },
    );

    try self.send(
        .remove_fragments,
        try data.toOwnedSlice(),
        .{
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );
}

/// `removeSignals` sends signals to the browser to be removed from the signals.
///
/// See the [Datastar documentation](https://data-star.dev/reference/sse_events#datastar-remove-signals) for more information.
pub fn removeSignals(
    self: *@This(),
    paths: []const []const u8,
    options: RemoveSignalsOptions,
) !void {
    var data = ArrayList(u8).empty;
    errdefer data.deinit(self.allocator);
    const writer = data.writer();

    for (paths) |path| {
        try writer.print(
            consts.paths_dataline_literal ++ " {s}\n",
            .{
                path,
            },
        );
    }

    try self.send(
        .remove_signals,
        try data.toOwnedSlice(),
        .{
            .event_id = options.event_id,
            .retry_duration = options.retry_duration,
        },
    );
}

/// `redirect` sends an `executeScript` event to redirect the user to a new URL.
pub fn redirect(
    self: *@This(),
    url: []const u8,
    options: ExecuteScriptOptions,
) !void {
    const script = try std.fmt.allocPrint(
        self.allocator,
        "setTimeout(() => window.location.href = '{s}')",
        .{url},
    );
    errdefer self.allocator.free(script);
    try self.executeScript(script, options);
}

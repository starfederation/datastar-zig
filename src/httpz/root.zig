const std = @import("std");
const httpz = @import("httpz");
const consts = @import("../consts.zig");
const testing = @import("../testing.zig");

pub const ServerSentEventGenerator = @import("ServerSentEventGenerator.zig");

/// `readSignals` is a helper function that reads datastar signals from the request.
pub fn readSignals(comptime T: type, req: *httpz.Request) !T {
    switch (req.method) {
        .GET => {
            const query = try req.query();
            const signals = query.get(consts.datastar_key) orelse return error.MissingDatastarKey;

            return std.json.parseFromSliceLeaky(T, req.arena, signals, .{});
        },
        else => {
            const body = req.body() orelse return error.MissingBody;

            return std.json.parseFromSliceLeaky(T, req.arena, body, .{});
        },
    }
}

fn sdk(req: *httpz.Request, res: *httpz.Response) !void {
    var sse = try ServerSentEventGenerator.init(res);
    const signals = try readSignals(
        testing.Signals,
        req,
    );

    try testing.sdk(&sse, signals);
}

test sdk {
    var server = try httpz.Server(void).init(
        std.testing.allocator,
        .{ .port = 8080 },
        {},
    );
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});

    router.get("/test", sdk, .{});
    router.post("/test", sdk, .{});

    try server.listen();
}

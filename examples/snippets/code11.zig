== File handler with variable mime type ==

// Note the URL is just 'mime' + filename
r.get("/mime/:filename");

fn mimeTest(http: *HTTPRequest) !void {
    const filename = http.params.get("filename") orelse return error.NoFilename;
    return http.sendFile(
        try std.fmt.allocPrint(
            http.arena,
            // we translate this to a filename under this dir
            "examples/assets/mime-tests/{s}",
            .{filename},
        ),
        null,
    );
}

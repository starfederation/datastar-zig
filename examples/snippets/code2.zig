== patchElements handler ==

var sse = try http.NewSSE();
defer sse.close();

try sse.patchElementsFmt(
    \\<p id="mf-patch">This is update number {d}</p>
,
    .{getCountAndIncrement()},
    .{},
);

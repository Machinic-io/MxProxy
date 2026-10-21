const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Production reverse proxy: ReleaseFast by default; pass -Drelease=false
    // for a Debug build. Debug was verified clean for the shutdown path (the
    // blocking accept loop is woken by a throwaway connection, never by
    // closing the listener, so no EBADF surfaces).
    const optimize = if (b.option(bool, "release", "optimize for end users") orelse true)
        std.builtin.Optimize.fast
    else
        std.builtin.Optimize.debug;

    // Release builds strip the binary. The 0.17 ELF linker embeds full DWARF
    // in release artifacts by default (the unstripped x86_64-linux release
    // binary is ~15MB, ~12MB of it .debug_* sections); stripping brings it to
    // ~2.3MB. Debug builds keep their debug info.
    const strip = optimize != .debug;

    // curl — link against the system libcurl by default. Pass
    // -Dlink_vendor=true to build the vendored libcurl (zig-curl compiles
    // libcurl + mbedtls + zlib from source with zig cc) instead; that is
    // what the release workflow uses, so every target can be cross-compiled
    // from a single Linux runner without target libcurl headers.
    const link_vendor = b.option(
        bool,
        "link_vendor",
        "link the vendored libcurl (with its own TLS) instead of the system libcurl",
    ) orelse false;
    const curl_dep = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = link_vendor,
    });
    const curl_module = curl_dep.module("curl");

    // httpx — reused only for the HTTP/1.1 parser, writer, and tcp sockets.
    // The httpx router/server are intentionally NOT used (they buffer bodies).
    const httpx_dep = b.dependency("httpx", .{
        .target = target,
        .optimize = optimize,
    });
    const httpx_module = httpx_dep.module("httpx");

    // regex — the regex engine behind the "regex" path-mapping type.
    const regex_dep = b.dependency("regex", .{
        .target = target,
        .optimize = optimize,
    });
    const regex_module = regex_dep.module("regex");

    // pathmap — the PathMapping interface + plain/regex implementations. Kept in
    // its own module so config (which builds path mappings) and router (which
    // dispatches them) can share it without an import cycle.
    const mod_pathmap = b.addModule("pathmap", .{
        .root_source_file = b.path("src/pathmap.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_pathmap.addImport("regex", regex_module);

    // config — configuration structs + JSON decoding/validation.
    const mod_config = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_config.addImport("pathmap", mod_pathmap);

    // router — path matching/rewriting (plain + regex, dispatch via the
    // PathMapping vtable).
    const mod_router = b.addModule("router", .{
        .root_source_file = b.path("src/router.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_router.addImport("config", mod_config);
    mod_router.addImport("pathmap", mod_pathmap);

    // headers — hop-by-hop filtering + header override application.
    const mod_headers = b.addModule("headers", .{
        .root_source_file = b.path("src/headers.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_headers.addImport("httpx", httpx_module);

    // forward — the core proxy: parse request, resolve route, drive one curl easy.
    const mod_forward = b.addModule("forward", .{
        .root_source_file = b.path("src/forward.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod_forward.addImport("config", mod_config);
    mod_forward.addImport("router", mod_router);
    mod_forward.addImport("headers", mod_headers);
    mod_forward.addImport("httpx", httpx_module);
    mod_forward.addImport("curl", curl_module);

    // server — accept loop + thread-per-connection + signal handling.
    const mod_server = b.addModule("server", .{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod_server.addImport("config", mod_config);
    mod_server.addImport("router", mod_router);
    mod_server.addImport("forward", mod_forward);
    mod_server.addImport("httpx", httpx_module);

    // main — entry point: CLI + config, globalInit, start the server.
    const main_module = b.addModule("MxProxy", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    main_module.addImport("config", mod_config);
    main_module.addImport("router", mod_router);
    main_module.addImport("headers", mod_headers);
    main_module.addImport("forward", mod_forward);
    main_module.addImport("server", mod_server);
    main_module.addImport("httpx", httpx_module);
    main_module.addImport("curl", curl_module);

    const exe = b.addExecutable(.{
        .name = "MxProxy",
        .root_module = main_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the proxy server");
    run_step.dependOn(&run_cmd.step);

    // Integration tests: in-process upstream + proxy + client.
    const test_module = b.addModule("proxy_test", .{
        .root_source_file = b.path("test/proxy_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addImport("config", mod_config);
    test_module.addImport("router", mod_router);
    test_module.addImport("headers", mod_headers);
    test_module.addImport("forward", mod_forward);
    test_module.addImport("server", mod_server);
    test_module.addImport("httpx", httpx_module);
    test_module.addImport("curl", curl_module);

    const tests = b.addTest(.{
        .name = "test",
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);

    // Router unit tests: a separate root exercising the router and the
    // path-rewrite (replacement) logic directly — no config load, no network.
    const router_test_module = b.addModule("router_test", .{
        .root_source_file = b.path("test/router_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    router_test_module.addImport("config", mod_config);
    router_test_module.addImport("pathmap", mod_pathmap);
    router_test_module.addImport("router", mod_router);

    const router_tests = b.addTest(.{
        .name = "router_test",
        .root_module = router_test_module,
    });
    const run_router_tests = b.addRunArtifact(router_tests);

    const test_step = b.step("test", "Run proxy tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_router_tests.step);
}

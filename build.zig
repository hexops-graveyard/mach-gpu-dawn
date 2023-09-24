const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const options = Options{
        .install_libs = true,
        .from_source = true,
    };
    // Just to demonstrate/test linking. This is not a functional example, see the mach/gpu examples
    // or Dawn C++ examples for functional example code.
    const example = b.addExecutable(.{
        .name = "dawn-example",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    link(b, example, options);
    b.installArtifact(example);

    const example_step = b.step("example", "Run library tests");
    example_step.dependOn(&b.addRunArtifact(example).step);
}

pub const LinkStep = struct {
    target: *std.build.Step.Compile,
    options: Options,
    step: std.build.Step,
    b: *std.build.Builder,

    pub fn init(b: *std.build.Builder, target: *std.build.Step.Compile, options: Options) *LinkStep {
        const link_step = b.allocator.create(LinkStep) catch unreachable;
        link_step.* = .{
            .target = target,
            .options = options,
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "link",
                .owner = b,
                .makeFn = &make,
            }),
            .b = b,
        };
        return link_step;
    }

    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) anyerror!void {
        _ = prog_node;
        const link_step = @fieldParentPtr(LinkStep, "step", step);
        try doLink(link_step.b, link_step.target, link_step.options);
    }
};

pub const Options = struct {
    /// Defaults to true on Windows
    d3d12: ?bool = null,

    /// Defaults to true on Darwin
    metal: ?bool = null,

    /// Defaults to true on Linux, Fuchsia
    // TODO(build-system): enable on Windows if we can cross compile Vulkan
    vulkan: ?bool = null,

    /// Defaults to true on Linux
    desktop_gl: ?bool = null,

    /// Defaults to true on Android, Linux, Windows, Emscripten
    // TODO(build-system): not respected at all currently
    opengl_es: ?bool = null,

    /// Whether or not minimal debug symbols should be emitted. This is -g1 in most cases, enough to
    /// produce stack traces but omitting debug symbols for locals. For spirv-tools and tint in
    /// specific, -g0 will be used (no debug symbols at all) to save an additional ~39M.
    debug: bool = false,

    /// Whether or not to produce separate static libraries for each component of Dawn (reduces
    /// iteration times when building from source / testing changes to Dawn source code.)
    separate_libs: bool = false,

    /// Whether or not to produce shared libraries instead of static ones
    shared_libs: bool = false,

    /// Whether to build Dawn from source or not.
    from_source: bool = false,

    /// Produce static libraries at zig-out/lib
    install_libs: bool = false,

    /// The binary release version to use from https://github.com/hexops/mach-gpu-dawn/releases
    binary_version: []const u8 = "release-d7b308b",

    /// Detects the default options to use for the given target.
    pub fn detectDefaults(self: Options, target: std.Target) Options {
        const tag = target.os.tag;

        var options = self;
        if (options.d3d12 == null) options.d3d12 = tag == .windows;
        if (options.metal == null) options.metal = tag.isDarwin();
        if (options.vulkan == null) options.vulkan = tag == .fuchsia or isLinuxDesktopLike(tag);

        // TODO(build-system): technically Dawn itself defaults desktop_gl to true on Windows.
        if (options.desktop_gl == null) options.desktop_gl = isLinuxDesktopLike(tag);

        // TODO(build-system): OpenGL ES
        options.opengl_es = false;
        // if (options.opengl_es == null) options.opengl_es = tag == .windows or tag == .emscripten or target.isAndroid() or linux_desktop_like;

        return options;
    }
};

pub fn link(b: *Build, step: *std.build.CompileStep, options: Options) void {
    var link_step = LinkStep.init(b, step, options);
    step.step.dependOn(&link_step.step);
}

pub fn doLink(b: *Build, step: *std.build.CompileStep, options: Options) !void {
    const opt = options.detectDefaults(step.target_info.target);

    if (step.target_info.target.os.tag == .windows) @import("direct3d_headers").addLibraryPath(step);
    if (step.target_info.target.os.tag == .macos) @import("xcode_frameworks").addPaths(b, step);

    if (options.from_source or isEnvVarTruthy(b.allocator, "DAWN_FROM_SOURCE"))
        try linkFromSource(b, step, opt)
    else
        try linkFromBinary(b, step, opt);
}

fn linkFromSource(b: *Build, step: *std.build.CompileStep, options: Options) !void {
    try ensureGitRepoCloned(b.allocator, "https://github.com/hexops/dawn", "generated-2023-08-10.1691685418", sdkPath("/libs/dawn"));

    // branch: mach
    try ensureGitRepoCloned(b.allocator, "https://github.com/hexops/DirectXShaderCompiler", "bb5211aa247978e2ab75bea9f5c985ba3fabd269", sdkPath("/libs/DirectXShaderCompiler"));

    step.addIncludePath(.{ .path = sdkPath("/libs/dawn/out/Debug/gen/include") });
    step.addIncludePath(.{ .path = sdkPath("/libs/dawn/include") });
    step.addIncludePath(.{ .path = sdkPath("/src/dawn") });

    if (options.separate_libs) {
        const lib_dawn_common = try buildLibDawnCommon(b, step, options);
        const lib_dawn_platform = try buildLibDawnPlatform(b, step, options);
        const lib_abseil_cpp = try buildLibAbseilCpp(b, step, options);
        const lib_dawn_native = try buildLibDawnNative(b, step, options);
        const lib_dawn_wire = try buildLibDawnWire(b, step, options);
        const lib_spirv_tools = try buildLibSPIRVTools(b, step, options);
        const lib_tint = try buildLibTint(b, step, options);

        step.linkLibrary(lib_dawn_common);
        step.linkLibrary(lib_dawn_platform);
        step.linkLibrary(lib_abseil_cpp);
        step.linkLibrary(lib_dawn_native);
        step.linkLibrary(lib_dawn_wire);
        step.linkLibrary(lib_spirv_tools);
        step.linkLibrary(lib_tint);

        if (options.d3d12.?) {
            const lib_dxcompiler = try buildLibDxcompiler(b, step, options);
            step.linkLibrary(lib_dxcompiler);
        }
        return;
    }

    const lib_dawn = if (options.shared_libs) b.addSharedLibrary(.{
        .name = "dawn",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    }) else b.addStaticLibrary(.{
        .name = "dawn",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    });
    step.linkLibrary(lib_dawn);

    _ = try buildLibDawnCommon(b, lib_dawn, options);
    _ = try buildLibDawnPlatform(b, lib_dawn, options);
    _ = try buildLibAbseilCpp(b, lib_dawn, options);
    _ = try buildLibDawnNative(b, lib_dawn, options);
    _ = try buildLibDawnWire(b, lib_dawn, options);
    _ = try buildLibSPIRVTools(b, lib_dawn, options);
    _ = try buildLibTint(b, lib_dawn, options);
    if (options.d3d12.?) _ = try buildLibDxcompiler(b, lib_dawn, options);
}

fn ensureGitRepoCloned(allocator: std.mem.Allocator, clone_url: []const u8, revision: []const u8, dir: []const u8) !void {
    if (isEnvVarTruthy(allocator, "NO_ENSURE_SUBMODULES") or isEnvVarTruthy(allocator, "NO_ENSURE_GIT")) {
        return;
    }

    ensureGit(allocator);

    if (std.fs.openDirAbsolute(dir, .{})) |_| {
        const current_revision = try getCurrentGitRevision(allocator, dir);
        if (!std.mem.eql(u8, current_revision, revision)) {
            // Reset to the desired revision
            exec(allocator, &[_][]const u8{ "git", "fetch" }, dir) catch |err| std.debug.print("warning: failed to 'git fetch' in {s}: {s}\n", .{ dir, @errorName(err) });
            try exec(allocator, &[_][]const u8{ "git", "checkout", "--quiet", "--force", revision }, dir);
            try exec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
        }
        return;
    } else |err| return switch (err) {
        error.FileNotFound => {
            std.log.info("cloning required dependency..\ngit clone {s} {s}..\n", .{ clone_url, dir });

            try exec(allocator, &[_][]const u8{ "git", "clone", "-c", "core.longpaths=true", clone_url, dir }, sdkPath("/"));
            try exec(allocator, &[_][]const u8{ "git", "checkout", "--quiet", "--force", revision }, dir);
            try exec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
            return;
        },
        else => err,
    };
}

fn exec(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !void {
    var child = std.ChildProcess.init(argv, allocator);
    child.cwd = cwd;
    _ = try child.spawnAndWait();
}

fn getCurrentGitRevision(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const result = try std.ChildProcess.exec(.{ .allocator = allocator, .argv = &.{ "git", "rev-parse", "HEAD" }, .cwd = cwd });
    allocator.free(result.stderr);
    if (result.stdout.len > 0) return result.stdout[0 .. result.stdout.len - 1]; // trim newline
    return result.stdout;
}

fn ensureGit(allocator: std.mem.Allocator) void {
    const argv = &[_][]const u8{ "git", "--version" };
    const result = std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = ".",
    }) catch { // e.g. FileNotFound
        std.log.err("mach: error: 'git --version' failed. Is git not installed?", .{});
        std.process.exit(1);
    };
    defer {
        allocator.free(result.stderr);
        allocator.free(result.stdout);
    }
    if (result.term.Exited != 0) {
        std.log.err("mach: error: 'git --version' failed. Is git not installed?", .{});
        std.process.exit(1);
    }
}

fn isEnvVarTruthy(allocator: std.mem.Allocator, name: []const u8) bool {
    if (std.process.getEnvVarOwned(allocator, name)) |truthy| {
        defer allocator.free(truthy);
        if (std.mem.eql(u8, truthy, "true")) return true;
        return false;
    } else |_| {
        return false;
    }
}

fn getGitHubBaseURLOwned(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "MACH_GITHUB_BASE_URL")) |base_url| {
        std.log.info("mach: respecting MACH_GITHUB_BASE_URL: {s}\n", .{base_url});
        return base_url;
    } else |_| {
        return allocator.dupe(u8, "https://github.com");
    }
}

pub fn linkFromBinary(b: *Build, step: *std.build.CompileStep, options: Options) !void {
    const target = step.target_info.target;
    const binaries_available = switch (target.os.tag) {
        .windows => target.abi.isGnu(),
        .linux => (target.cpu.arch.isX86() or target.cpu.arch.isAARCH64()) and (target.abi.isGnu() or target.abi.isMusl()),
        .macos => blk: {
            if (!target.cpu.arch.isX86() and !target.cpu.arch.isAARCH64()) break :blk false;

            // The minimum macOS version with which our binaries can be used.
            const min_available = std.SemanticVersion{ .major = 11, .minor = 0, .patch = 0 };

            // If the target version is >= the available version, then it's OK.
            const order = target.os.version_range.semver.min.order(min_available);
            break :blk (order == .gt or order == .eq);
        },
        else => false,
    };
    if (!binaries_available) {
        const zig_triple = try target.zigTriple(b.allocator);
        std.log.err("gpu-dawn binaries for {s} not available.", .{zig_triple});
        std.log.err("-> open an issue: https://github.com/hexops/mach/issues", .{});
        std.log.err("-> build from source (takes 5-15 minutes):", .{});
        std.log.err("    set `DAWN_FROM_SOURCE` environment variable or `Options.from_source` to `true`\n", .{});
        if (target.os.tag == .macos) {
            std.log.err("", .{});
            if (target.cpu.arch.isX86()) std.log.err("-> Did you mean to use -Dtarget=x86_64-macos.12.0...13.1-none ?", .{});
            if (target.cpu.arch.isAARCH64()) std.log.err("-> Did you mean to use -Dtarget=aarch64-macos.12.0...13.1-none ?", .{});
        }
        std.process.exit(1);
    }

    // Remove OS version range / glibc version from triple (we do not include that in our download
    // URLs.)
    var binary_target = std.zig.CrossTarget.fromTarget(target);
    binary_target.os_version_min = .{ .none = undefined };
    binary_target.os_version_max = .{ .none = undefined };
    binary_target.glibc_version = null;
    const zig_triple = try binary_target.zigTriple(b.allocator);
    try ensureBinaryDownloaded(b.allocator, zig_triple, options.debug, target.os.tag == .windows, options.binary_version);

    const base_cache_dir_rel = try std.fs.path.join(b.allocator, &.{ "zig-cache", "mach", "gpu-dawn" });
    try std.fs.cwd().makePath(base_cache_dir_rel);
    const base_cache_dir = try std.fs.cwd().realpathAlloc(b.allocator, base_cache_dir_rel);
    const commit_cache_dir = try std.fs.path.join(b.allocator, &.{ base_cache_dir, options.binary_version });
    const release_tag = if (options.debug) "debug" else "release-fast";
    const target_cache_dir = try std.fs.path.join(b.allocator, &.{ commit_cache_dir, zig_triple, release_tag });
    const include_dir = try std.fs.path.join(b.allocator, &.{ commit_cache_dir, "include" });

    step.addLibraryPath(.{ .path = target_cache_dir });
    step.linkSystemLibraryName("dawn");
    step.linkLibCpp();

    step.addIncludePath(.{ .path = include_dir });
    step.addIncludePath(.{ .path = sdkPath("/src/dawn") });

    linkLibDawnCommonDependencies(b, step, options);
    linkLibDawnPlatformDependencies(b, step, options);
    linkLibDawnNativeDependencies(b, step, options);
    linkLibTintDependencies(b, step, options);
    linkLibSPIRVToolsDependencies(b, step, options);
    linkLibAbseilCppDependencies(b, step, options);
    linkLibDawnWireDependencies(b, step, options);
    linkLibDxcompilerDependencies(b, step, options);
}

pub fn ensureBinaryDownloaded(
    allocator: std.mem.Allocator,
    zig_triple: []const u8,
    is_debug: bool,
    is_windows: bool,
    version: []const u8,
) !void {
    // If zig-cache/mach/gpu-dawn/<git revision> does not exist:
    //   If on a commit in the main branch => rm -r zig-cache/mach/gpu-dawn/
    //   else => noop
    // If zig-cache/mach/gpu-dawn/<git revision>/<target> exists:
    //   noop
    // else:
    //   Download archive to zig-cache/mach/gpu-dawn/download/macos-aarch64
    //   Extract to zig-cache/mach/gpu-dawn/<git revision>/macos-aarch64/libgpu.a
    //   Remove zig-cache/mach/gpu-dawn/download

    const base_cache_dir_rel = try std.fs.path.join(allocator, &.{ "zig-cache", "mach", "gpu-dawn" });
    try std.fs.cwd().makePath(base_cache_dir_rel);
    const base_cache_dir = try std.fs.cwd().realpathAlloc(allocator, base_cache_dir_rel);
    const commit_cache_dir = try std.fs.path.join(allocator, &.{ base_cache_dir, version });
    defer {
        allocator.free(base_cache_dir_rel);
        allocator.free(base_cache_dir);
        allocator.free(commit_cache_dir);
    }

    if (!dirExists(commit_cache_dir)) {
        // Commit cache dir does not exist. If the commit we're on is in the main branch, we're
        // probably moving to a newer commit and so we should cleanup older cached binaries.
        const current_git_commit = try getCurrentGitCommit(allocator);
        if (gitBranchContainsCommit(allocator, "main", current_git_commit) catch false) {
            std.fs.deleteTreeAbsolute(base_cache_dir) catch {};
        }
    }

    const release_tag = if (is_debug) "debug" else "release-fast";
    const target_cache_dir = try std.fs.path.join(allocator, &.{ commit_cache_dir, zig_triple, release_tag });
    defer allocator.free(target_cache_dir);
    if (dirExists(target_cache_dir)) {
        return; // nothing to do, already have the binary
    }
    downloadBinary(allocator, commit_cache_dir, release_tag, target_cache_dir, zig_triple, is_windows, version) catch |err| {
        // A download failed, or extraction failed, so wipe out the directory to ensure we correctly
        // try again next time.
        std.fs.deleteTreeAbsolute(base_cache_dir) catch {};
        std.log.err("mach/gpu-dawn: prebuilt binary download failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn downloadBinary(
    allocator: std.mem.Allocator,
    commit_cache_dir: []const u8,
    release_tag: []const u8,
    target_cache_dir: []const u8,
    zig_triple: []const u8,
    is_windows: bool,
    version: []const u8,
) !void {
    ensureCanDownloadFiles(allocator);

    const download_dir = try std.fs.path.join(allocator, &.{ target_cache_dir, "download" });
    defer allocator.free(download_dir);
    try std.fs.cwd().makePath(download_dir);

    // Replace "..." with "---" because GitHub releases has very weird restrictions on file names.
    // https://twitter.com/slimsag/status/1498025997987315713
    const github_triple = try std.mem.replaceOwned(u8, allocator, zig_triple, "...", "---");
    defer allocator.free(github_triple);

    // Compose the download URL, e.g.:
    // https://github.com/hexops/mach-gpu-dawn/releases/download/release-6b59025/libdawn_x86_64-macos-none_debug.a.gz
    const github_base_url = try getGitHubBaseURLOwned(allocator);
    defer allocator.free(github_base_url);
    const lib_prefix = if (is_windows) "dawn_" else "libdawn_";
    const lib_ext = if (is_windows) ".lib" else ".a";
    const lib_file_name = if (is_windows) "dawn.lib" else "libdawn.a";
    const download_url = try std.mem.concat(allocator, u8, &.{
        github_base_url,
        "/hexops/mach-gpu-dawn/releases/download/",
        version,
        "/",
        lib_prefix,
        github_triple,
        "_",
        release_tag,
        lib_ext,
        ".gz",
    });
    defer allocator.free(download_url);

    // Download and decompress libdawn
    const gz_target_file = try std.fs.path.join(allocator, &.{ download_dir, "compressed.gz" });
    defer allocator.free(gz_target_file);
    try downloadFile(allocator, gz_target_file, download_url);
    const target_file = try std.fs.path.join(allocator, &.{ target_cache_dir, lib_file_name });
    defer allocator.free(target_file);
    try gzipDecompress(allocator, gz_target_file, target_file);

    // If we don't yet have the headers (these are shared across architectures), download them.
    const include_dir = try std.fs.path.join(allocator, &.{ commit_cache_dir, "include" });
    defer allocator.free(include_dir);
    if (!dirExists(include_dir)) {
        // Compose the headers download URL, e.g.:
        // https://github.com/hexops/mach-gpu-dawn/releases/download/release-6b59025/headers.json.gz
        const headers_download_url = try std.mem.concat(allocator, u8, &.{
            github_base_url,
            "/hexops/mach-gpu-dawn/releases/download/",
            version,
            "/headers.json.gz",
        });
        defer allocator.free(headers_download_url);

        // Download and decompress headers.json.gz
        const headers_gz_target_file = try std.fs.path.join(allocator, &.{ download_dir, "headers.json.gz" });
        defer allocator.free(headers_gz_target_file);
        try downloadFile(allocator, headers_gz_target_file, headers_download_url);
        const headers_target_file = try std.fs.path.join(allocator, &.{ target_cache_dir, "headers.json" });
        defer allocator.free(headers_target_file);
        try gzipDecompress(allocator, headers_gz_target_file, headers_target_file);

        // Extract headers JSON archive.
        try extractHeaders(allocator, headers_target_file, commit_cache_dir);
    }

    try std.fs.deleteTreeAbsolute(download_dir);
}

fn extractHeaders(allocator: std.mem.Allocator, json_file: []const u8, out_dir: []const u8) !void {
    const contents = try std.fs.cwd().readFileAlloc(allocator, json_file, std.math.maxInt(usize));
    defer allocator.free(contents);

    var tree = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer tree.deinit();

    var iter = tree.value.object.iterator();
    while (iter.next()) |f| {
        const out_path = try std.fs.path.join(allocator, &.{ out_dir, f.key_ptr.* });
        defer allocator.free(out_path);
        try std.fs.cwd().makePath(std.fs.path.dirname(out_path).?);

        var new_file = try std.fs.createFileAbsolute(out_path, .{});
        defer new_file.close();
        try new_file.writeAll(f.value_ptr.*.string);
    }
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn gzipDecompress(allocator: std.mem.Allocator, src_absolute_path: []const u8, dst_absolute_path: []const u8) !void {
    var file = try std.fs.openFileAbsolute(src_absolute_path, .{ .mode = .read_only });
    defer file.close();

    var buf_stream = std.io.bufferedReader(file.reader());
    var gzip_stream = try std.compress.gzip.decompress(allocator, buf_stream.reader());
    defer gzip_stream.deinit();

    // Read and decompress the whole file
    const buf = try gzip_stream.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(buf);

    var new_file = try std.fs.createFileAbsolute(dst_absolute_path, .{});
    defer new_file.close();

    try new_file.writeAll(buf);
}

fn gitBranchContainsCommit(allocator: std.mem.Allocator, branch: []const u8, commit: []const u8) !bool {
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &.{ "git", "branch", branch, "--contains", commit },
        .cwd = sdkPath("/"),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return result.term.Exited == 0;
}

fn getCurrentGitCommit(allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .cwd = sdkPath("/"),
    });
    defer allocator.free(result.stderr);
    if (result.stdout.len > 0) return result.stdout[0 .. result.stdout.len - 1]; // trim newline
    return result.stdout;
}

fn gitClone(allocator: std.mem.Allocator, repository: []const u8, dir: []const u8) !bool {
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &.{ "git", "clone", repository, dir },
        .cwd = sdkPath("/"),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return result.term.Exited == 0;
}

fn downloadFile(allocator: std.mem.Allocator, target_file: []const u8, url: []const u8) !void {
    std.debug.print("downloading {s}..\n", .{url});

    // Some Windows users experience `SSL certificate problem: unable to get local issuer certificate`
    // so we give them the option to disable SSL if they desire / don't want to debug the issue.
    var child = if (isEnvVarTruthy(allocator, "CURL_INSECURE"))
        std.ChildProcess.init(&.{ "curl", "--insecure", "-L", "-o", target_file, url }, allocator)
    else
        std.ChildProcess.init(&.{ "curl", "-L", "-o", target_file, url }, allocator);
    child.cwd = sdkPath("/");
    child.stderr = std.io.getStdErr();
    child.stdout = std.io.getStdOut();
    _ = try child.spawnAndWait();
}

fn ensureCanDownloadFiles(allocator: std.mem.Allocator) void {
    const result = std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &.{ "curl", "--version" },
        .cwd = sdkPath("/"),
    }) catch { // e.g. FileNotFound
        std.log.err("mach: error: 'curl --version' failed. Is curl not installed?", .{});
        std.process.exit(1);
    };
    defer {
        allocator.free(result.stderr);
        allocator.free(result.stdout);
    }
    if (result.term.Exited != 0) {
        std.log.err("mach: error: 'curl --version' failed. Is curl not installed?", .{});
        std.process.exit(1);
    }
}

fn isLinuxDesktopLike(tag: std.Target.Os.Tag) bool {
    return switch (tag) {
        .linux,
        .freebsd,
        .kfreebsd,
        .openbsd,
        .dragonfly,
        => true,
        else => false,
    };
}

pub fn appendFlags(step: *std.build.CompileStep, flags: *std.ArrayList([]const u8), debug_symbols: bool, is_cpp: bool) !void {
    if (debug_symbols) try flags.append("-g1") else try flags.append("-g0");
    if (is_cpp) try flags.append("-std=c++17");
    if (isLinuxDesktopLike(step.target_info.target.os.tag)) {
        step.defineCMacro("DAWN_USE_X11", "1");
        step.defineCMacro("DAWN_USE_WAYLAND", "1");
    }
}

fn linkLibDawnCommonDependencies(b: *Build, step: *std.build.CompileStep, options: Options) void {
    _ = options;
    step.linkLibCpp();
    if (step.target_info.target.os.tag == .macos) {
        @import("xcode_frameworks").addPaths(b, step);
        step.linkSystemLibraryName("objc");
        step.linkFramework("Foundation");
    }
}

// Builds common sources; derived from src/common/BUILD.gn
fn buildLibDawnCommon(b: *Build, step: *std.build.CompileStep, options: Options) !*std.build.CompileStep {
    const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
        .name = "dawn-common",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    }) else b.addStaticLibrary(.{
        .name = "dawn-common",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    });
    if (options.install_libs) b.installArtifact(lib);
    linkLibDawnCommonDependencies(b, lib, options);

    if (lib.target_info.target.os.tag == .linux) lib.linkLibrary(b.dependency("x11_headers", .{
        .target = lib.target,
        .optimize = lib.optimize,
    }).artifact("x11-headers"));

    defineDawnEnableBackend(lib, options);

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(&.{
        include("libs/dawn/src"),
        include("libs/dawn/out/Debug/gen/include"),
        include("libs/dawn/out/Debug/gen/src"),
    });
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/src/dawn/common/",
            "libs/dawn/out/Debug/gen/src/dawn/common/",
        },
        .flags = flags.items,
        .excluding_contains = &.{
            "test",
            "benchmark",
            "mock",
            "WindowsUtils.cpp",
        },
    });

    var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
    if (step.target_info.target.os.tag == .macos) {
        // TODO(build-system): pass system SDK options through
        const abs_path = sdkPath("/libs/dawn/src/dawn/common/SystemUtils_mac.mm");
        try cpp_sources.append(abs_path);
    }
    if (step.target_info.target.os.tag == .windows) {
        const abs_path = sdkPath("/libs/dawn/src/dawn/common/WindowsUtils.cpp");
        try cpp_sources.append(abs_path);
    }

    var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
    try cpp_flags.appendSlice(flags.items);
    try appendFlags(lib, &cpp_flags, options.debug, true);
    lib.addCSourceFiles(cpp_sources.items, cpp_flags.items);
    return lib;
}

fn linkLibDawnPlatformDependencies(b: *Build, step: *std.build.CompileStep, options: Options) void {
    _ = b;
    _ = options;
    step.linkLibCpp();
}

// Build dawn platform sources; derived from src/dawn/platform/BUILD.gn
fn buildLibDawnPlatform(b: *Build, step: *std.build.CompileStep, options: Options) !*std.build.CompileStep {
    const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
        .name = "dawn-platform",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    }) else b.addStaticLibrary(.{
        .name = "dawn-platform",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    });
    if (options.install_libs) b.installArtifact(lib);
    linkLibDawnPlatformDependencies(b, lib, options);

    var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
    try appendFlags(lib, &cpp_flags, options.debug, true);
    try cpp_flags.appendSlice(&.{
        include("libs/dawn/src"),
        include("libs/dawn/include"),

        include("libs/dawn/out/Debug/gen/include"),
    });

    var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
    inline for ([_][]const u8{
        "src/dawn/platform/metrics/HistogramMacros.cpp",
        "src/dawn/platform/tracing/EventTracer.cpp",
        "src/dawn/platform/WorkerThread.cpp",
        "src/dawn/platform/DawnPlatform.cpp",
    }) |path| {
        const abs_path = sdkPath("/libs/dawn/" ++ path);
        try cpp_sources.append(abs_path);
    }

    lib.addCSourceFiles(cpp_sources.items, cpp_flags.items);
    return lib;
}

fn defineDawnEnableBackend(step: *std.build.CompileStep, options: Options) void {
    step.defineCMacro("DAWN_ENABLE_BACKEND_NULL", "1");
    // TODO: support the Direct3D 11 backend
    // if (options.d3d11.?) step.defineCMacro("DAWN_ENABLE_BACKEND_D3D11", "1");
    if (options.d3d12.?) step.defineCMacro("DAWN_ENABLE_BACKEND_D3D12", "1");
    if (options.metal.?) step.defineCMacro("DAWN_ENABLE_BACKEND_METAL", "1");
    if (options.vulkan.?) step.defineCMacro("DAWN_ENABLE_BACKEND_VULKAN", "1");
    if (options.desktop_gl.?) {
        step.defineCMacro("DAWN_ENABLE_BACKEND_OPENGL", "1");
        step.defineCMacro("DAWN_ENABLE_BACKEND_DESKTOP_GL", "1");
    }
    if (options.opengl_es.?) {
        step.defineCMacro("DAWN_ENABLE_BACKEND_OPENGL", "1");
        step.defineCMacro("DAWN_ENABLE_BACKEND_OPENGLES", "1");
    }
}

fn linkLibDawnNativeDependencies(b: *Build, step: *std.build.CompileStep, options: Options) void {
    step.linkLibCpp();
    if (options.d3d12.?) {
        step.linkLibrary(b.dependency("direct3d_headers", .{
            .target = step.target,
            .optimize = step.optimize,
        }).artifact("direct3d-headers"));
    }
    if (options.metal.?) {
        @import("xcode_frameworks").addPaths(b, step);
        step.linkSystemLibraryName("objc");
        step.linkFramework("Metal");
        step.linkFramework("CoreGraphics");
        step.linkFramework("Foundation");
        step.linkFramework("IOKit");
        step.linkFramework("IOSurface");
        step.linkFramework("QuartzCore");
    }
}

// Builds dawn native sources; derived from src/dawn/native/BUILD.gn
fn buildLibDawnNative(b: *Build, step: *std.build.CompileStep, options: Options) !*std.build.CompileStep {
    const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
        .name = "dawn-native",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    }) else b.addStaticLibrary(.{
        .name = "dawn-native",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    });
    if (options.install_libs) b.installArtifact(lib);
    linkLibDawnNativeDependencies(b, lib, options);

    if (options.vulkan.?) lib.linkLibrary(b.dependency("vulkan_headers", .{
        .target = lib.target,
        .optimize = lib.optimize,
    }).artifact("vulkan-headers"));
    if (lib.target_info.target.os.tag == .linux) lib.linkLibrary(b.dependency("x11_headers", .{
        .target = lib.target,
        .optimize = lib.optimize,
    }).artifact("x11-headers"));

    // MacOS: this must be defined for macOS 13.3 and older.
    // Critically, this MUST NOT be included as a -D__kernel_ptr_semantics flag. If it is,
    // then this macro will not be defined even if `defineCMacro` was also called!
    lib.defineCMacro("__kernel_ptr_semantics", "");

    lib.defineCMacro("_HRESULT_DEFINED", "");
    lib.defineCMacro("HRESULT", "long");
    defineDawnEnableBackend(lib, options);

    // TODO(build-system): make these optional
    lib.defineCMacro("TINT_BUILD_SPV_READER", "1");
    lib.defineCMacro("TINT_BUILD_SPV_WRITER", "1");
    lib.defineCMacro("TINT_BUILD_WGSL_READER", "1");
    lib.defineCMacro("TINT_BUILD_WGSL_WRITER", "1");
    lib.defineCMacro("TINT_BUILD_MSL_WRITER", "1");
    lib.defineCMacro("TINT_BUILD_HLSL_WRITER", "1");
    lib.defineCMacro("TINT_BUILD_GLSL_WRITER", "1");
    lib.defineCMacro("DAWN_NO_WINDOWS_UI", "1");

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(&.{
        include("libs/dawn"),
        include("libs/dawn/src"),
        include("libs/dawn/include"),
        include("libs/dawn/third_party/vulkan-deps/spirv-tools/src/include"),
        include("libs/dawn/third_party/khronos"),

        "-Wno-deprecated-declarations",
        include("libs/dawn/third_party/abseil-cpp"),

        include("libs/dawn/"),
        include("libs/dawn/include/tint"),
        include("libs/dawn/third_party/vulkan-deps/vulkan-tools/src/"),

        include("libs/dawn/out/Debug/gen/include"),
        include("libs/dawn/out/Debug/gen/src"),
    });
    if (options.d3d12.?) {
        lib.defineCMacro("DAWN_NO_WINDOWS_UI", "");
        lib.defineCMacro("__EMULATE_UUID", "");
        lib.defineCMacro("_CRT_SECURE_NO_WARNINGS", "");
        lib.defineCMacro("WIN32_LEAN_AND_MEAN", "");
        lib.defineCMacro("D3D10_ARBITRARY_HEADER_ORDERING", "");
        lib.defineCMacro("NOMINMAX", "");
        try flags.appendSlice(&.{
            "-Wno-nonportable-include-path",
            "-Wno-extern-c-compat",
            "-Wno-invalid-noreturn",
            "-Wno-pragma-pack",
            "-Wno-microsoft-template-shadow",
            "-Wno-unused-command-line-argument",
            "-Wno-microsoft-exception-spec",
            "-Wno-implicit-exception-spec-mismatch",
            "-Wno-unknown-attributes",
            "-Wno-c++20-extensions",
        });
    }

    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/out/Debug/gen/src/dawn/",
            "libs/dawn/src/dawn/native/",
            "libs/dawn/src/dawn/native/utils/",
            "libs/dawn/src/dawn/native/stream/",
        },
        .flags = flags.items,
        .excluding_contains = if (options.shared_libs) &.{
            "test",
            "benchmark",
            "mock",
            "SpirvValidation.cpp",
            "X11Functions.cpp",
            "dawn_proc.c",
        } else &.{
            "test",
            "benchmark",
            "mock",
            "SpirvValidation.cpp",
            "X11Functions.cpp",
            "dawn_proc.c",
        },
    });

    // dawn_native_gen
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/out/Debug/gen/src/dawn/native/",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "benchmark", "mock", "webgpu_dawn_native_proc.cpp" },
    });

    // TODO(build-system): could allow enable_vulkan_validation_layers here. See src/dawn/native/BUILD.gn
    // TODO(build-system): allow use_angle here. See src/dawn/native/BUILD.gn
    // TODO(build-system): could allow use_swiftshader here. See src/dawn/native/BUILD.gn

    var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
    if (options.d3d12.?) {
        inline for ([_][]const u8{
            "src/dawn/mingw_helpers.cpp",
        }) |path| {
            const abs_path = sdkPath("/" ++ path);
            try cpp_sources.append(abs_path);
        }

        try appendLangScannedSources(b, lib, .{
            .rel_dirs = &.{
                "libs/dawn/src/dawn/native/d3d/",
                "libs/dawn/src/dawn/native/d3d12/",
            },
            .flags = flags.items,
            .excluding_contains = &.{ "test", "benchmark", "mock" },
        });
    }
    if (options.metal.?) {
        try appendLangScannedSources(b, lib, .{
            .objc = true,
            .rel_dirs = &.{
                "libs/dawn/src/dawn/native/metal/",
                "libs/dawn/src/dawn/native/",
            },
            .flags = flags.items,
            .excluding_contains = &.{ "test", "benchmark", "mock" },
        });
    }

    const tag = step.target_info.target.os.tag;
    if (isLinuxDesktopLike(tag)) {
        inline for ([_][]const u8{
            "src/dawn/native/X11Functions.cpp",
        }) |path| {
            const abs_path = sdkPath("/libs/dawn/" ++ path);
            try cpp_sources.append(abs_path);
        }
    }

    inline for ([_][]const u8{
        "src/dawn/native/null/DeviceNull.cpp",
    }) |path| {
        const abs_path = sdkPath("/libs/dawn/" ++ path);
        try cpp_sources.append(abs_path);
    }

    if (options.desktop_gl.? or options.vulkan.?) {
        inline for ([_][]const u8{
            "src/dawn/native/SpirvValidation.cpp",
        }) |path| {
            const abs_path = sdkPath("/libs/dawn/" ++ path);
            try cpp_sources.append(abs_path);
        }
    }

    if (options.desktop_gl.?) {
        try appendLangScannedSources(b, lib, .{
            .rel_dirs = &.{
                "libs/dawn/out/Debug/gen/src/dawn/native/opengl/",
                "libs/dawn/src/dawn/native/opengl/",
            },
            .flags = flags.items,
            .excluding_contains = &.{ "test", "benchmark", "mock" },
        });
    }

    if (options.vulkan.?) {
        try appendLangScannedSources(b, lib, .{
            .rel_dirs = &.{
                "libs/dawn/src/dawn/native/vulkan/",
            },
            .flags = flags.items,
            .excluding_contains = &.{ "test", "benchmark", "mock" },
        });
        try cpp_sources.append(sdkPath("/libs/dawn/" ++ "src/dawn/native/vulkan/external_memory/MemoryService.cpp"));
        try cpp_sources.append(sdkPath("/libs/dawn/" ++ "src/dawn/native/vulkan/external_memory/MemoryServiceImplementation.cpp"));
        try cpp_sources.append(sdkPath("/libs/dawn/" ++ "src/dawn/native/vulkan/external_memory/MemoryServiceImplementationDmaBuf.cpp"));
        try cpp_sources.append(sdkPath("/libs/dawn/" ++ "src/dawn/native/vulkan/external_semaphore/SemaphoreService.cpp"));
        try cpp_sources.append(sdkPath("/libs/dawn/" ++ "src/dawn/native/vulkan/external_semaphore/SemaphoreServiceImplementation.cpp"));

        if (isLinuxDesktopLike(tag)) {
            inline for ([_][]const u8{
                "src/dawn/native/vulkan/external_memory/MemoryServiceImplementationOpaqueFD.cpp",
                "src/dawn/native/vulkan/external_semaphore/SemaphoreServiceImplementationFD.cpp",
            }) |path| {
                const abs_path = sdkPath("/libs/dawn/" ++ path);
                try cpp_sources.append(abs_path);
            }
        } else if (tag == .fuchsia) {
            inline for ([_][]const u8{
                "src/dawn/native/vulkan/external_memory/MemoryServiceImplementationZirconHandle.cpp",
                "src/dawn/native/vulkan/external_semaphore/SemaphoreServiceImplementationZirconHandle.cpp",
            }) |path| {
                const abs_path = sdkPath("/libs/dawn/" ++ path);
                try cpp_sources.append(abs_path);
            }
        } else if (step.target_info.target.isAndroid()) {
            inline for ([_][]const u8{
                "src/dawn/native/vulkan/external_memory/MemoryServiceImplementationAHardwareBuffer.cpp",
                "src/dawn/native/vulkan/external_semaphore/SemaphoreServiceImplementationFD.cpp",
            }) |path| {
                const abs_path = sdkPath("/libs/dawn/" ++ path);
                try cpp_sources.append(abs_path);
            }
            lib.defineCMacro("DAWN_USE_SYNC_FDS", "1");
        }
    }

    // TODO(build-system): fuchsia: add is_fuchsia here from upstream source file

    if (options.vulkan.?) {
        // TODO(build-system): vulkan
        //     if (enable_vulkan_validation_layers) {
        //       defines += [
        //         "DAWN_ENABLE_VULKAN_VALIDATION_LAYERS",
        //         "DAWN_VK_DATA_DIR=\"$vulkan_data_subdir\"",
        //       ]
        //     }
        //     if (enable_vulkan_loader) {
        //       data_deps += [ "${dawn_vulkan_loader_dir}:libvulkan" ]
        //       defines += [ "DAWN_ENABLE_VULKAN_LOADER" ]
        //     }
    }
    // TODO(build-system): swiftshader
    //     if (use_swiftshader) {
    //       data_deps += [
    //         "${dawn_swiftshader_dir}/src/Vulkan:icd_file",
    //         "${dawn_swiftshader_dir}/src/Vulkan:swiftshader_libvulkan",
    //       ]
    //       defines += [
    //         "DAWN_ENABLE_SWIFTSHADER",
    //         "DAWN_SWIFTSHADER_VK_ICD_JSON=\"${swiftshader_icd_file_name}\"",
    //       ]
    //     }
    //   }

    if (options.opengl_es.?) {
        // TODO(build-system): gles
        //   if (use_angle) {
        //     data_deps += [
        //       "${dawn_angle_dir}:libEGL",
        //       "${dawn_angle_dir}:libGLESv2",
        //     ]
        //   }
        // }
    }

    inline for ([_][]const u8{
        "src/dawn/native/null/NullBackend.cpp",
    }) |path| {
        const abs_path = sdkPath("/libs/dawn/" ++ path);
        try cpp_sources.append(abs_path);
    }

    if (options.d3d12.?) {
        inline for ([_][]const u8{
            "src/dawn/native/d3d12/D3D12Backend.cpp",
        }) |path| {
            const abs_path = sdkPath("/libs/dawn/" ++ path);
            try cpp_sources.append(abs_path);
        }
    }

    var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
    try cpp_flags.appendSlice(flags.items);
    try appendFlags(lib, &cpp_flags, options.debug, true);
    lib.addCSourceFiles(cpp_sources.items, cpp_flags.items);
    return lib;
}

fn linkLibTintDependencies(b: *Build, step: *std.build.CompileStep, options: Options) void {
    _ = b;
    _ = options;
    step.linkLibCpp();
}

// Builds tint sources; derived from src/tint/BUILD.gn
fn buildLibTint(b: *Build, step: *std.build.CompileStep, options: Options) !*std.build.CompileStep {
    const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
        .name = "tint",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    }) else b.addStaticLibrary(.{
        .name = "tint",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    });
    if (options.install_libs) b.installArtifact(lib);
    linkLibTintDependencies(b, lib, options);

    lib.defineCMacro("_HRESULT_DEFINED", "");
    lib.defineCMacro("HRESULT", "long");

    // TODO(build-system): make these optional
    lib.defineCMacro("TINT_BUILD_SPV_READER", "1");
    lib.defineCMacro("TINT_BUILD_SPV_WRITER", "1");
    lib.defineCMacro("TINT_BUILD_WGSL_READER", "1");
    lib.defineCMacro("TINT_BUILD_WGSL_WRITER", "1");
    lib.defineCMacro("TINT_BUILD_MSL_WRITER", "1");
    lib.defineCMacro("TINT_BUILD_HLSL_WRITER", "1");
    lib.defineCMacro("TINT_BUILD_GLSL_WRITER", "1");
    lib.defineCMacro("TINT_BUILD_SYNTAX_TREE_WRITER", "1");

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(&.{
        include("libs/dawn/"),
        include("libs/dawn/include/tint"),

        // Required for TINT_BUILD_SPV_READER=1 and TINT_BUILD_SPV_WRITER=1, if specified
        include("libs/dawn/third_party/vulkan-deps"),
        include("libs/dawn/third_party/vulkan-deps/spirv-tools/src"),
        include("libs/dawn/third_party/vulkan-deps/spirv-tools/src/include"),
        include("libs/dawn/third_party/vulkan-deps/spirv-headers/src/include"),
        include("libs/dawn/out/Debug/gen/third_party/vulkan-deps/spirv-tools/src"),
        include("libs/dawn/out/Debug/gen/third_party/vulkan-deps/spirv-tools/src/include"),
        include("libs/dawn/include"),
        include("libs/dawn/third_party/abseil-cpp"),
    });

    // TODO: split out libtint builds, provide an example of building: src/tint/cmd

    // libtint_core_all_src
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/src/tint",
            "libs/dawn/src/tint/lang/core/",
            "libs/dawn/src/tint/lang/core/intrinsic/",
            "libs/dawn/src/tint/lang/core/intrinsic/data",
            "libs/dawn/src/tint/lang/core/constant/",
            "libs/dawn/src/tint/lang/core/ir/",
            "libs/dawn/src/tint/lang/core/ir/transform/",
            "libs/dawn/src/tint/lang/core/type/",

            // "libs/dawn/src/tint/utils/cli",
            // "libs/dawn/src/tint/utils/file",
            // "libs/dawn/src/tint/utils/command",
            "libs/dawn/src/tint/utils/containers",
            "libs/dawn/src/tint/utils/debug",
            "libs/dawn/src/tint/utils/diagnostic",
            "libs/dawn/src/tint/utils/generator",
            "libs/dawn/src/tint/utils/ice",
            "libs/dawn/src/tint/utils/id",
            "libs/dawn/src/tint/utils/macros",
            "libs/dawn/src/tint/utils/math",
            "libs/dawn/src/tint/utils/memory",
            "libs/dawn/src/tint/utils/reflection",
            "libs/dawn/src/tint/utils/result",
            "libs/dawn/src/tint/utils/rtti",
            "libs/dawn/src/tint/utils/strconv",
            "libs/dawn/src/tint/utils/symbol",
            "libs/dawn/src/tint/utils/templates",
            "libs/dawn/src/tint/utils/text",
            "libs/dawn/src/tint/utils/traits",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "bench", "printer_windows", "printer_posix", "printer_other", "glsl.cc" },
    });

    var cpp_sources = std.ArrayList([]const u8).init(b.allocator);

    const tag = step.target_info.target.os.tag;
    if (tag == .windows) {
        try cpp_sources.append(sdkPath("/libs/dawn/src/tint/utils/diagnostic/printer_windows.cc"));
    } else if (tag.isDarwin() or isLinuxDesktopLike(tag)) {
        try cpp_sources.append(sdkPath("/libs/dawn/src/tint/utils/diagnostic/printer_posix.cc"));
    } else {
        try cpp_sources.append(sdkPath("/libs/dawn/src/tint/utils/diagnostic/printer_other.cc"));
    }

    // libtint_sem_src
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/src/tint/lang/wgsl/sem/",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "benchmark" },
    });

    // spirv
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/src/tint/lang/spirv/reader",
            "libs/dawn/src/tint/lang/spirv/reader/ast_parser",
            "libs/dawn/src/tint/lang/spirv/writer",
            "libs/dawn/src/tint/lang/spirv/writer/ast_printer",
            "libs/dawn/src/tint/lang/spirv/writer/common",
            "libs/dawn/src/tint/lang/spirv/writer/printer",
            "libs/dawn/src/tint/lang/spirv/writer/raise",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "bench" },
    });

    // wgsl
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/src/tint/lang/wgsl/reader",
            "libs/dawn/src/tint/lang/wgsl/reader/parser",
            "libs/dawn/src/tint/lang/wgsl/reader/program_to_ir",
            "libs/dawn/src/tint/lang/wgsl/ast",
            "libs/dawn/src/tint/lang/wgsl/ast/transform",
            "libs/dawn/src/tint/lang/wgsl/helpers",
            "libs/dawn/src/tint/lang/wgsl/inspector",
            "libs/dawn/src/tint/lang/wgsl/program",
            "libs/dawn/src/tint/lang/wgsl/resolver",
            "libs/dawn/src/tint/lang/wgsl/writer",
            "libs/dawn/src/tint/lang/wgsl/writer/ast_printer",
            "libs/dawn/src/tint/lang/wgsl/writer/ir_to_program",
            "libs/dawn/src/tint/lang/wgsl/writer/syntax_tree_printer",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "bench" },
    });

    // msl
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/src/tint/lang/msl/writer",
            "libs/dawn/src/tint/lang/msl/writer/ast_printer",
            "libs/dawn/src/tint/lang/msl/writer/common",
            "libs/dawn/src/tint/lang/msl/writer/printer",
            "libs/dawn/src/tint/lang/msl/validate",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "bench" },
    });

    // hlsl
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/src/tint/lang/hlsl/writer",
            "libs/dawn/src/tint/lang/hlsl/writer/ast_printer",
            "libs/dawn/src/tint/lang/hlsl/writer/common",
            "libs/dawn/src/tint/lang/hlsl/validate",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "bench" },
    });

    // glsl
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/src/tint/lang/glsl/",
            "libs/dawn/src/tint/lang/glsl/writer",
            "libs/dawn/src/tint/lang/glsl/writer/ast_printer",
            "libs/dawn/src/tint/lang/glsl/writer/common",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "bench" },
    });

    var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
    try cpp_flags.appendSlice(flags.items);
    try appendFlags(lib, &cpp_flags, options.debug, true);
    lib.addCSourceFiles(cpp_sources.items, cpp_flags.items);
    return lib;
}

fn linkLibSPIRVToolsDependencies(b: *Build, step: *std.build.CompileStep, options: Options) void {
    _ = b;
    _ = options;
    step.linkLibCpp();
}

// Builds third_party/vulkan-deps/spirv-tools sources; derived from third_party/vulkan-deps/spirv-tools/src/BUILD.gn
fn buildLibSPIRVTools(b: *Build, step: *std.build.CompileStep, options: Options) !*std.build.CompileStep {
    const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
        .name = "spirv-tools",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    }) else b.addStaticLibrary(.{
        .name = "spirv-tools",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    });
    if (options.install_libs) b.installArtifact(lib);
    linkLibSPIRVToolsDependencies(b, lib, options);

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(&.{
        include("libs/dawn"),
        include("libs/dawn/third_party/vulkan-deps/spirv-tools/src"),
        include("libs/dawn/third_party/vulkan-deps/spirv-tools/src/include"),
        include("libs/dawn/third_party/vulkan-deps/spirv-headers/src/include"),
        include("libs/dawn/out/Debug/gen/third_party/vulkan-deps/spirv-tools/src"),
        include("libs/dawn/out/Debug/gen/third_party/vulkan-deps/spirv-tools/src/include"),
        include("libs/dawn/third_party/vulkan-deps/spirv-headers/src/include/spirv/unified1"),
    });

    // spvtools
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/third_party/vulkan-deps/spirv-tools/src/source/",
            "libs/dawn/third_party/vulkan-deps/spirv-tools/src/source/util/",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "benchmark" },
    });

    // spvtools_val
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/third_party/vulkan-deps/spirv-tools/src/source/val/",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "benchmark" },
    });

    // spvtools_opt
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/third_party/vulkan-deps/spirv-tools/src/source/opt/",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "benchmark" },
    });

    // spvtools_link
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/third_party/vulkan-deps/spirv-tools/src/source/link/",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "benchmark" },
    });
    return lib;
}

fn linkLibAbseilCppDependencies(b: *Build, step: *std.build.CompileStep, options: Options) void {
    _ = options;
    step.linkLibCpp();
    const target = step.target_info.target;
    if (target.os.tag == .macos) {
        @import("xcode_frameworks").addPaths(b, step);
        step.linkSystemLibraryName("objc");
        step.linkFramework("CoreFoundation");
    }
    if (target.os.tag == .windows) step.linkSystemLibraryName("bcrypt");
}

// Builds third_party/abseil sources; derived from:
//
// ```
// $ find third_party/abseil-cpp/absl | grep '\.cc' | grep -v 'test' | grep -v 'benchmark' | grep -v gaussian_distribution_gentables | grep -v print_hash_of | grep -v chi_square
// ```
//
fn buildLibAbseilCpp(b: *Build, step: *std.build.CompileStep, options: Options) !*std.build.CompileStep {
    const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
        .name = "abseil",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    }) else b.addStaticLibrary(.{
        .name = "abseil",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    });
    if (options.install_libs) b.installArtifact(lib);
    linkLibAbseilCppDependencies(b, lib, options);

    const target = step.target_info.target;

    // musl needs this defined in order for off64_t to be a type, which abseil-cpp uses
    lib.defineCMacro("_FILE_OFFSET_BITS", "64");
    lib.defineCMacro("_LARGEFILE64_SOURCE", "");

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(&.{
        include("libs/dawn"),
        include("libs/dawn/third_party/abseil-cpp"),
        "-Wno-deprecated-declarations",
    });
    if (target.os.tag == .windows) {
        lib.defineCMacro("ABSL_FORCE_THREAD_IDENTITY_MODE", "2");
        lib.defineCMacro("WIN32_LEAN_AND_MEAN", "");
        lib.defineCMacro("D3D10_ARBITRARY_HEADER_ORDERING", "");
        lib.defineCMacro("_CRT_SECURE_NO_WARNINGS", "");
        lib.defineCMacro("NOMINMAX", "");
        try flags.append(include("src/dawn/zig_mingw_pthread"));
    }

    // absl
    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/third_party/abseil-cpp/absl/strings/",
            "libs/dawn/third_party/abseil-cpp/absl/strings/internal/",
            "libs/dawn/third_party/abseil-cpp/absl/strings/internal/str_format/",
            "libs/dawn/third_party/abseil-cpp/absl/types/",
            "libs/dawn/third_party/abseil-cpp/absl/flags/internal/",
            "libs/dawn/third_party/abseil-cpp/absl/flags/",
            "libs/dawn/third_party/abseil-cpp/absl/synchronization/",
            "libs/dawn/third_party/abseil-cpp/absl/synchronization/internal/",
            "libs/dawn/third_party/abseil-cpp/absl/hash/internal/",
            "libs/dawn/third_party/abseil-cpp/absl/debugging/",
            "libs/dawn/third_party/abseil-cpp/absl/debugging/internal/",
            "libs/dawn/third_party/abseil-cpp/absl/status/",
            "libs/dawn/third_party/abseil-cpp/absl/time/internal/cctz/src/",
            "libs/dawn/third_party/abseil-cpp/absl/time/",
            "libs/dawn/third_party/abseil-cpp/absl/container/internal/",
            "libs/dawn/third_party/abseil-cpp/absl/numeric/",
            "libs/dawn/third_party/abseil-cpp/absl/random/",
            "libs/dawn/third_party/abseil-cpp/absl/random/internal/",
            "libs/dawn/third_party/abseil-cpp/absl/base/internal/",
            "libs/dawn/third_party/abseil-cpp/absl/base/",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "_test", "_testing", "benchmark", "print_hash_of.cc", "gaussian_distribution_gentables.cc" },
    });
    return lib;
}

fn linkLibDawnWireDependencies(b: *Build, step: *std.build.CompileStep, options: Options) void {
    _ = b;
    _ = options;
    step.linkLibCpp();
}

// Buids dawn wire sources; derived from src/dawn/wire/BUILD.gn
fn buildLibDawnWire(b: *Build, step: *std.build.CompileStep, options: Options) !*std.build.CompileStep {
    const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
        .name = "dawn-wire",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    }) else b.addStaticLibrary(.{
        .name = "dawn-wire",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    });
    if (options.install_libs) b.installArtifact(lib);
    linkLibDawnWireDependencies(b, lib, options);

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(&.{
        include("libs/dawn"),
        include("libs/dawn/src"),
        include("libs/dawn/include"),
        include("libs/dawn/out/Debug/gen/include"),
        include("libs/dawn/out/Debug/gen/src"),
    });

    try appendLangScannedSources(b, lib, .{
        .rel_dirs = &.{
            "libs/dawn/out/Debug/gen/src/dawn/wire/",
            "libs/dawn/out/Debug/gen/src/dawn/wire/client/",
            "libs/dawn/out/Debug/gen/src/dawn/wire/server/",
            "libs/dawn/src/dawn/wire/",
            "libs/dawn/src/dawn/wire/client/",
            "libs/dawn/src/dawn/wire/server/",
        },
        .flags = flags.items,
        .excluding_contains = &.{ "test", "benchmark", "mock" },
    });
    return lib;
}

fn linkLibDxcompilerDependencies(b: *Build, step: *std.build.CompileStep, options: Options) void {
    if (options.d3d12.?) {
        step.linkLibCpp();
        step.linkLibrary(b.dependency("direct3d_headers", .{
            .target = step.target,
            .optimize = step.optimize,
        }).artifact("direct3d-headers"));
        @import("direct3d_headers").addLibraryPath(step);

        step.linkSystemLibraryName("oleaut32");
        step.linkSystemLibraryName("ole32");
        step.linkSystemLibraryName("dbghelp");
    }
}

// Buids dxcompiler sources; derived from libs/DirectXShaderCompiler/CMakeLists.txt
fn buildLibDxcompiler(b: *Build, step: *std.build.CompileStep, options: Options) !*std.build.CompileStep {
    const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
        .name = "dxcompiler",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    }) else b.addStaticLibrary(.{
        .name = "dxcompiler",
        .target = step.target,
        .optimize = if (options.debug) .Debug else .ReleaseFast,
    });
    if (options.install_libs) b.installArtifact(lib);
    linkLibDxcompilerDependencies(b, lib, options);

    lib.defineCMacro("UNREFERENCED_PARAMETER(x)", "");
    lib.defineCMacro("MSFT_SUPPORTS_CHILD_PROCESSES", "1");
    lib.defineCMacro("HAVE_LIBPSAPI", "1");
    lib.defineCMacro("HAVE_LIBSHELL32", "1");
    lib.defineCMacro("LLVM_ON_WIN32", "1");

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(&.{
        include("libs/"),
        include("libs/DirectXShaderCompiler/include/llvm/llvm_assert"),
        include("libs/DirectXShaderCompiler/include"),
        include("libs/DirectXShaderCompiler/build/include"),
        include("libs/DirectXShaderCompiler/build/lib/HLSL"),
        include("libs/DirectXShaderCompiler/build/lib/DxilPIXPasses"),
        include("libs/DirectXShaderCompiler/build/include"),
        "-Wno-inconsistent-missing-override",
        "-Wno-missing-exception-spec",
        "-Wno-switch",
        "-Wno-deprecated-declarations",
        "-Wno-macro-redefined", // regex2.h and regcomp.c requires this for OUT redefinition
    });

    try appendLangScannedSources(b, lib, .{
        .debug_symbols = false,
        .rel_dirs = &.{
            "libs/DirectXShaderCompiler/lib/Analysis/IPA",
            "libs/DirectXShaderCompiler/lib/Analysis",
            "libs/DirectXShaderCompiler/lib/AsmParser",
            "libs/DirectXShaderCompiler/lib/Bitcode/Writer",
            "libs/DirectXShaderCompiler/lib/DxcBindingTable",
            "libs/DirectXShaderCompiler/lib/DxcSupport",
            "libs/DirectXShaderCompiler/lib/DxilContainer",
            "libs/DirectXShaderCompiler/lib/DxilPIXPasses",
            "libs/DirectXShaderCompiler/lib/DxilRootSignature",
            "libs/DirectXShaderCompiler/lib/DXIL",
            "libs/DirectXShaderCompiler/lib/DxrFallback",
            "libs/DirectXShaderCompiler/lib/HLSL",
            "libs/DirectXShaderCompiler/lib/IRReader",
            "libs/DirectXShaderCompiler/lib/IR",
            "libs/DirectXShaderCompiler/lib/Linker",
            "libs/DirectXShaderCompiler/lib/Miniz",
            "libs/DirectXShaderCompiler/lib/Option",
            "libs/DirectXShaderCompiler/lib/PassPrinters",
            "libs/DirectXShaderCompiler/lib/Passes",
            "libs/DirectXShaderCompiler/lib/ProfileData",
            "libs/DirectXShaderCompiler/lib/Target",
            "libs/DirectXShaderCompiler/lib/Transforms/InstCombine",
            "libs/DirectXShaderCompiler/lib/Transforms/IPO",
            "libs/DirectXShaderCompiler/lib/Transforms/Scalar",
            "libs/DirectXShaderCompiler/lib/Transforms/Utils",
            "libs/DirectXShaderCompiler/lib/Transforms/Vectorize",
        },
        .flags = flags.items,
    });

    try appendLangScannedSources(b, lib, .{
        .debug_symbols = false,
        .rel_dirs = &.{
            "libs/DirectXShaderCompiler/lib/Support",
        },
        .flags = flags.items,
        .excluding_contains = &.{
            "DynamicLibrary.cpp", // ignore, HLSL_IGNORE_SOURCES
            "PluginLoader.cpp", // ignore, HLSL_IGNORE_SOURCES
            "Path.cpp", // ignore, LLVM_INCLUDE_TESTS
            "DynamicLibrary.cpp", // ignore
        },
    });

    try appendLangScannedSources(b, lib, .{
        .debug_symbols = false,
        .rel_dirs = &.{
            "libs/DirectXShaderCompiler/lib/Bitcode/Reader",
        },
        .flags = flags.items,
        .excluding_contains = &.{
            "BitReader.cpp", // ignore
        },
    });
    return lib;
}

fn appendLangScannedSources(
    b: *Build,
    step: *std.build.CompileStep,
    args: struct {
        debug_symbols: bool = false,
        flags: []const []const u8,
        rel_dirs: []const []const u8 = &.{},
        objc: bool = false,
        excluding: []const []const u8 = &.{},
        excluding_contains: []const []const u8 = &.{},
    },
) !void {
    var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
    try cpp_flags.appendSlice(args.flags);
    try appendFlags(step, &cpp_flags, args.debug_symbols, true);
    const cpp_extensions: []const []const u8 = if (args.objc) &.{".mm"} else &.{ ".cpp", ".cc" };
    try appendScannedSources(b, step, .{
        .flags = cpp_flags.items,
        .rel_dirs = args.rel_dirs,
        .extensions = cpp_extensions,
        .excluding = args.excluding,
        .excluding_contains = args.excluding_contains,
    });

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(args.flags);
    try appendFlags(step, &flags, args.debug_symbols, false);
    const c_extensions: []const []const u8 = if (args.objc) &.{".m"} else &.{".c"};
    try appendScannedSources(b, step, .{
        .flags = flags.items,
        .rel_dirs = args.rel_dirs,
        .extensions = c_extensions,
        .excluding = args.excluding,
        .excluding_contains = args.excluding_contains,
    });
}

fn appendScannedSources(b: *Build, step: *std.build.CompileStep, args: struct {
    flags: []const []const u8,
    rel_dirs: []const []const u8 = &.{},
    extensions: []const []const u8,
    excluding: []const []const u8 = &.{},
    excluding_contains: []const []const u8 = &.{},
}) !void {
    var sources = std.ArrayList([]const u8).init(b.allocator);
    for (args.rel_dirs) |rel_dir| {
        try scanSources(b, &sources, rel_dir, args.extensions, args.excluding, args.excluding_contains);
    }
    step.addCSourceFiles(sources.items, args.flags);
}

/// Scans rel_dir for sources ending with one of the provided extensions, excluding relative paths
/// listed in the excluded list.
/// Results are appended to the dst ArrayList.
fn scanSources(
    b: *Build,
    dst: *std.ArrayList([]const u8),
    rel_dir: []const u8,
    extensions: []const []const u8,
    excluding: []const []const u8,
    excluding_contains: []const []const u8,
) !void {
    const abs_dir = try std.fs.path.join(b.allocator, &.{ sdkPath("/"), rel_dir });
    var dir = std.fs.openIterableDirAbsolute(abs_dir, .{}) catch |err| {
        std.log.err("mach: error: failed to open: {s}", .{abs_dir});
        return err;
    };
    defer dir.close();
    var dir_it = dir.iterate();
    while (try dir_it.next()) |entry| {
        if (entry.kind != .file) continue;
        var abs_path = try std.fs.path.join(b.allocator, &.{ abs_dir, entry.name });
        abs_path = try std.fs.realpathAlloc(b.allocator, abs_path);

        const allowed_extension = blk: {
            const ours = std.fs.path.extension(entry.name);
            for (extensions) |ext| {
                if (std.mem.eql(u8, ours, ext)) break :blk true;
            }
            break :blk false;
        };
        if (!allowed_extension) continue;

        const excluded = blk: {
            for (excluding) |excluded| {
                if (std.mem.eql(u8, entry.name, excluded)) break :blk true;
            }
            break :blk false;
        };
        if (excluded) continue;

        const excluded_contains = blk: {
            for (excluding_contains) |contains| {
                if (std.mem.containsAtLeast(u8, entry.name, 1, contains)) break :blk true;
            }
            break :blk false;
        };
        if (excluded_contains) continue;

        try dst.append(abs_path);
    }
}

fn include(comptime rel: []const u8) []const u8 {
    return comptime "-I" ++ sdkPath("/" ++ rel);
}

fn sdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cli_args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const Action = @import("ghostty.zig").Action;
const DiskCache = @import("ssh_cache.zig").DiskCache;
const persist = @import("persist.zig");
const internal_os = @import("../os/main.zig");
const ghostty_terminfo = @import("../terminfo/main.zig").ghostty;
const global = @import("../global.zig");

const log = std.log.scoped(.ssh);

const usage =
    \\Usage: ghostty +ssh [flags] [--] <ssh args...>
    \\
    \\Flags:
    \\  --forward-env[=bool]  Enable TERM / SendEnv forwarding. Default: true.
    \\  --terminfo[=bool]     Install Ghostty terminfo on first connect. Default: true.
    \\  --cache[=bool]        Use the terminfo install cache. Default: true.
    \\  --persist[=bool]      Run interactive sessions inside a persistent
    \\                        Ghostty-managed session that survives the
    \\                        local terminal closing. Default: false.
    \\  --persist-session=<name> Override the session name. Default: derived
    \\                        from the resolved destination (user@host).
    \\  --ssh=<path>          Path to the ssh binary. Default: first `ssh` on PATH.
    \\  --verbose             Print +ssh status lines to stderr.
    \\  --help                Show full help.
    \\
    \\ssh flags and the destination go after +ssh's own flags (or after `--`).
    \\
;

pub const Options = struct {
    /// Set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// Maps to the `ssh-env` shell integration feature.
    @"forward-env": bool = true,

    /// Maps to the `ssh-terminfo` shell integration feature.
    terminfo: bool = true,

    /// When false, both cache read and write are bypassed.
    cache: bool = true,

    /// Maps to the `ssh-persist` shell integration feature. When true,
    /// interactive sessions run inside a persistent Ghostty-managed
    /// session (`ghostty +persist`): the ssh process lives in a PTY
    /// owned by a background server, so the connection and its remote
    /// processes survive the local terminal closing and can be
    /// reattached later. This replaces the need for tmux on the remote
    /// host.
    persist: bool = false,

    /// Override the persist session name. By default the session name is
    /// derived from the resolved ssh destination (user@host).
    @"persist-session": ?[]const u8 = null,

    /// The wrapped `ssh` binary.
    /// `/`-containing values are treated as paths; otherwise resolved via PATH.
    ssh: []const u8 = "ssh",

    /// When true, print verbose output to stderr.
    verbose: bool = false,

    /// Arguments passed through to `ssh` verbatim. Populated by
    /// `parseManuallyHook` when we reach the first non-flag argument (or
    /// an explicit `--`).
    _ssh_args: std.ArrayList([]const u8) = .empty,

    /// Enables arg parsing diagnostics so unknown flags become
    /// diagnostics rather than fatal errors.
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(_: Options) !void {
        return Action.help_error;
    }

    /// Manual parse hook. For each argument:
    ///   - If it's a literal `--`, consume everything after it as ssh
    ///     args and stop parsing.
    ///   - If it doesn't start with `--`, this is the start of the ssh
    ///     argv. Consume this arg and everything after as ssh args and
    ///     stop parsing.
    ///   - Otherwise (a `--foo` arg), return true so the generic parser
    ///     handles it as one of our own flags.
    pub fn parseManuallyHook(
        self: *Options,
        alloc: Allocator,
        arg: []const u8,
        iter: anytype,
    ) Allocator.Error!bool {
        if (std.mem.eql(u8, arg, "--")) {
            while (iter.next()) |rest| {
                try self._ssh_args.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }

        if (!std.mem.startsWith(u8, arg, "--")) {
            try self._ssh_args.append(alloc, try alloc.dupe(u8, arg));
            while (iter.next()) |rest| {
                try self._ssh_args.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }

        return true;
    }
};

/// Wrap `ssh` to automatically configure Ghostty terminal integration on
/// remote hosts.
///
/// Any arguments that aren't recognized as `+ssh` flags are passed to
/// the real `ssh` binary unchanged. You can use `--` as an explicit
/// disambiguator if needed, though it's almost never required: `ssh`
/// has no long flags, and `+ssh` defines no short flags, so there's
/// nothing to collide.
///
/// This is typically called via Ghostty's shell integration. When
/// `shell-integration-features` includes `ssh-env` or `ssh-terminfo`,
/// each shell defines an `ssh` function that runs:
///
///     ghostty +ssh <flags> -- "$@"
///
/// You can also run `ghostty +ssh` directly, or alias it yourself (e.g.
/// `alias ssh='ghostty +ssh --'`) if you prefer not to use the shell
/// integration.
///
/// `+ssh` performs up to three pieces of setup before launching `ssh`:
///
///   1. **Environment forwarding** (`--forward-env`). Sets `TERM` to
///      `xterm-256color` and requests `SendEnv` forwarding of
///      `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION` so the
///      remote shell can still detect that it's running inside Ghostty.
///      The remote `sshd_config` must list these in `AcceptEnv` for
///      forwarding to succeed.
///
///   2. **Terminfo install** (`--terminfo`). On the first connection to a
///      given destination, installs Ghostty's terminfo entry on the remote
///      host using `infocmp -x xterm-ghostty | ssh tic -x -` over a
///      shared `ControlMaster` connection. Successful installs are cached
///      (see `ghostty +ssh-cache`) so subsequent connections skip this
///      step. When terminfo is successfully installed or already cached,
///      `TERM` is set to `xterm-ghostty` instead of `xterm-256color`.
///
///   3. **Persistent sessions** (`--persist`). Interactive sessions (no
///      remote command) run inside a Ghostty-managed daemon
///      (`ghostty +persist`): the ssh process lives in a PTY owned by a
///      background server, so closing the local terminal leaves the
///      connection and its remote processes running. Running the same
///      `ssh` command again — which Ghostty does automatically when a
///      surface is restored — reattaches to the session and replays
///      recent output. If the connection itself is lost (network drop,
///      sshd restart), the server reconnects with backoff while the
///      session lives. The session name is derived
///      from the resolved destination (`user@host`) and can be
///      overridden with `--persist-session`. This replaces the usual
///      "run tmux on the remote host" workflow; nothing needs to be
///      installed remotely.
///
/// If `--terminfo` install fails (e.g. `tic` not available on the
/// remote, filesystem permissions), a warning is logged and the
/// connection continues with `TERM=xterm-256color`.
///
/// Flags:
///
///   * `--forward-env=<bool>`: Enable `TERM` / `SendEnv` environment
///     forwarding. Default: `true`.
///
///   * `--terminfo=<bool>`: Enable automatic terminfo install on first
///     connection. Default: `true`.
///
///   * `--cache=<bool>`: Use the terminfo install cache. Default: `true`.
///     When `false`, both the cache read (skip-if-installed) and the
///     cache write (record-on-success) are bypassed, and every
///     connection performs the install. To one-shot reinstall a single
///     host while keeping the cache in use, prefer `ghostty +ssh-cache
///     --remove=<host>` followed by a normal connection.
///
///   * `--persist=<bool>`: Run interactive sessions inside a persistent
///     Ghostty-managed session. Default: `false`.
///
///   * `--persist-session=<name>`: Override the persist session name.
///     Default: `ghostty-<user>-<host>` derived from the resolved
///     destination.
///
///   * `--ssh=<path>`: Path to the `ssh` binary to execute. Default: the
///     first `ssh` found on `PATH`.
///
///   * `--verbose`: Print +ssh status lines to stderr, and surface
///     remote stderr during the terminfo install.
///
/// Examples:
///
///   # Basic invocation using defaults:
///   ghostty +ssh user@example.com
///
///   # Forward Ghostty env vars but skip the terminfo install:
///   ghostty +ssh --terminfo=false user@example.com
///
///   # `ssh` flags (short-form `-p`, etc.) pass through unchanged:
///   ghostty +ssh -p 2222 -i ~/.ssh/id_ed25519 user@example.com
///
///   # Use `--` explicitly if your ssh args might collide with our flags:
///   ghostty +ssh -- --some-rare-ssh-arg user@example.com
///
/// Pass `--verbose` to see what `+ssh` is doing. For cache inspection
/// and management, see `ghostty +ssh-cache`.
///
/// Available since: 1.4.0
pub fn run(alloc_gpa: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try cli_args.argsIterator(alloc_gpa, global.args());
        defer iter.deinit();
        try cli_args.parse(Options, alloc_gpa, &opts, &iter);
    }

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file: std.Io.File = .stderr();
    var stderr_writer = stderr_file.writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Any diagnostic from the arg parser is an unknown flag or bad
    // value. Reject loudly — silently forwarding `--typo` to ssh would
    // produce confusing downstream errors.
    if (!opts._diagnostics.empty()) {
        for (opts._diagnostics.items()) |diag| {
            if (diag.key.len > 0) {
                stderr.print(
                    "Error: unknown flag `--{s}`.\n",
                    .{diag.key},
                ) catch {};
            } else {
                stderr.print("Error: {s}\n", .{diag.message}) catch {};
            }
        }
        stderr.print("\n{s}", .{usage}) catch {};
        stderr.flush() catch {};
        return 2;
    }

    const result = runInner(alloc_gpa, &opts, stderr);

    stderr.flush() catch {};
    return result;
}

fn runInner(
    gpa: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (opts._ssh_args.items.len == 0) {
        try stderr.print("Error: no ssh arguments provided.\n\n{s}", .{usage});
        return 2;
    }

    // Resolve the destination once if any feature needs it. This runs
    // `ssh -G` which reads the user's ssh configuration.
    const resolved_dest: ?[]const u8 = if (opts.terminfo or opts.persist)
        resolveDestination(alloc, opts.ssh, opts._ssh_args.items)
    else
        null;

    const session: struct {
        term: []const u8,
        to_cache: ?struct { cache: DiskCache, dest: []const u8 } = null,
    } = session: {
        if (!opts.terminfo) break :session .{ .term = "xterm-256color" };

        const dest = resolved_dest orelse {
            warnPrint(stderr, "could not resolve ssh destination; skipping terminfo install", .{});
            break :session .{ .term = "xterm-256color" };
        };

        const cache: ?DiskCache = if (opts.cache) cache: {
            const path = DiskCache.defaultPath(alloc, "ghostty") catch |err| {
                warnPrint(stderr, "ghostty terminfo cache unavailable: {t}", .{err});
                break :session .{ .term = "xterm-256color" };
            };
            break :cache .{ .path = path };
        } else null;

        if (cache) |c| {
            const cached = c.contains(alloc, dest) catch |err| cached: {
                if (DiskCache.isFailure(err)) warnPrint(
                    stderr,
                    "unable to read the cache '{s}': {t}",
                    .{ c.path, err },
                );
                break :cached false;
            };

            if (cached) {
                verbosePrint(opts, stderr, "dest: {s} (cached, skipping install)", .{dest});
                break :session .{ .term = "xterm-ghostty" };
            } else {
                verbosePrint(opts, stderr, "dest: {s} (not cached, will install)", .{dest});
            }
        } else {
            verbosePrint(opts, stderr, "dest: {s} (cache disabled, will install)", .{dest});
        }

        stderr.print("Setting up xterm-ghostty terminfo on {s}...\n", .{dest}) catch {};
        stderr.flush() catch {};

        installRemoteTerminfo(alloc, opts, stderr) catch |err| {
            warnPrint(stderr, "failed to install terminfo: {t}", .{err});
            break :session .{ .term = "xterm-256color" };
        };
        break :session .{
            .term = "xterm-ghostty",
            .to_cache = if (cache) |c| .{ .cache = c, .dest = dest } else null,
        };
    };

    // Determine whether we will run inside a persistent session.
    const persist_plan: ?struct { session: []const u8 } = plan: {
        if (!opts.persist) break :plan null;

        _ = interactiveDestIdx(opts._ssh_args.items) orelse {
            verbosePrint(opts, stderr, "persist: not an interactive ssh session; skipping", .{});
            break :plan null;
        };

        const dest = resolved_dest orelse {
            warnPrint(stderr, "could not resolve ssh destination; skipping persistent session", .{});
            break :plan null;
        };

        const session_name = opts.@"persist-session" orelse try persist.sessionName(alloc, dest);
        verbosePrint(opts, stderr, "persist: session {s}", .{session_name});
        break :plan .{ .session = session_name };
    };

    // Build the full argv: [ssh, ...our opts, ...user args]
    const env_opts: []const []const u8 = if (opts.@"forward-env") env_opts: {
        const set_term = try std.fmt.allocPrint(
            alloc,
            "SetEnv=TERM={s}",
            .{session.term},
        );
        break :env_opts &.{
            "-o", set_term,
            "-o", "SendEnv=COLORTERM",
            "-o", "SendEnv=TERM_PROGRAM",
            "-o", "SendEnv=TERM_PROGRAM_VERSION",
        };
    } else &.{};
    const argv = try std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        env_opts,
        opts._ssh_args.items,
    });
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

    // Notify the terminal of the command that restores this session so
    // that it can be re-run when the surface is restored. This is only
    // done for persistent sessions since otherwise there is nothing
    // persistent to restore.
    if (persist_plan != null) writeRestoreCommand(alloc, opts._ssh_args.items);

    const exit_code = exit_code: {
        if (persist_plan) |plan| {
            // The ssh process runs inside the persist server's PTY and
            // this process becomes the attach client. When the attach
            // ends (terminal closed, or the remote session exited) the
            // server keeps the PTY alive for the next attach. The
            // server also restarts ssh with backoff when the connection
            // is lost (ssh exit 255) instead of ending the session.
            break :exit_code persist.attachCommand(gpa, plan.session, argv, true) catch |err| {
                writeRestoreCommand(alloc, null);
                try stderr.print("Error: failed to run {s}: {t}\n", .{ argv[0], err });
                return 1;
            };
        }

        break :exit_code childExec(argv) catch |err| {
            try stderr.print("Error: failed to run {s}: {t}\n", .{ argv[0], err });
            return 1;
        };
    };
    if (persist_plan != null) writeRestoreCommand(alloc, null);
    verbosePrint(opts, stderr, "exit: {d}", .{exit_code});

    // Attempt to cache (if needed) on a successful ssh execution.
    if (exit_code == 0) if (session.to_cache) |entry| {
        if (entry.cache.add(alloc, entry.dest, std.Io.Timestamp.now(
            global.io(),
            .real,
        ).toSeconds())) |_| {
            verbosePrint(opts, stderr, "cache: wrote {s}", .{entry.dest});
        } else |err| {
            if (DiskCache.isFailure(err)) {
                warnPrint(
                    stderr,
                    "unable to add '{s}' to the cache '{s}': {t}",
                    .{ entry.dest, entry.cache.path, err },
                );
            } else {
                verbosePrint(
                    opts,
                    stderr,
                    "cache: skipped {s}: {t}",
                    .{ entry.dest, err },
                );
            }
        }
    };

    return exit_code;
}

/// Log to `.ssh` and, if `--verbose`, also print to stderr.
fn verbosePrint(
    opts: *const Options,
    stderr: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log.debug(fmt, args);
    if (!opts.verbose) return;
    stderr.print("+ssh: " ++ fmt ++ "\n", args) catch return;
    stderr.flush() catch return;
}

/// Log a warning and also print a `Warning: <msg>` line to stderr.
fn warnPrint(
    stderr: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log.warn(fmt, args);
    stderr.print("Warning: " ++ fmt ++ "\n", args) catch return;
    stderr.flush() catch return;
}

/// Space-joined items, formattable as `{f}`.
const Joined = struct {
    items: []const []const u8,

    pub fn format(self: Joined, writer: *std.Io.Writer) !void {
        for (self.items, 0..) |a, i| {
            if (i > 0) try writer.writeByte(' ');
            try writer.writeAll(a);
        }
    }

    test {
        const testing = std.testing;
        var buf: [128]u8 = undefined;
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{} }});
            try testing.expectEqualStrings("", buf[0..w.end]);
        }
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{"only"} }});
            try testing.expectEqualStrings("only", buf[0..w.end]);
        }
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{ "a", "b", "c" } }});
            try testing.expectEqualStrings("a b c", buf[0..w.end]);
        }
    }
};

fn checkExit(term: std.process.Child.Term, label: []const u8) error{ChildFailed}!void {
    switch (term) {
        .exited => |rc| if (rc != 0) {
            log.warn("{s} exited with non-zero status: {d}", .{ label, rc });
            return error.ChildFailed;
        },
        else => {
            log.warn("{s} terminated abnormally: {}", .{ label, term });
            return error.ChildFailed;
        },
    }
}

/// Run `ssh -G <args>` and parse the output for `user` and `hostname`.
/// Returns the resolved `user@hostname`, or null if the destination
/// could not be resolved.
fn resolveDestination(
    alloc: Allocator,
    ssh: []const u8,
    args: []const []const u8,
) ?[]const u8 {
    const argv = std.mem.concat(alloc, []const u8, &.{
        &.{ ssh, "-G" },
        args,
    }) catch return null;
    const result = std.process.run(
        alloc,
        global.io(),
        .{ .argv = argv },
    ) catch |err| {
        log.warn("ssh -G spawn failed: {}", .{err});
        return null;
    };
    checkExit(result.term, "ssh -G") catch return null;
    return parseDestination(alloc, result.stdout);
}

/// Parse `ssh -G` output for `user` and `hostname` and return the
/// formatted `user@hostname`. Returns null if either key is missing
/// or formatting fails.
fn parseDestination(alloc: Allocator, stdout: []const u8) ?[]const u8 {
    var user: []const u8 = "";
    var host: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const value = line[space + 1 ..];
        if (std.mem.eql(u8, key, "user")) {
            user = value;
        } else if (std.mem.eql(u8, key, "hostname")) {
            host = value;
        }
        if (user.len > 0 and host.len > 0) break;
    }

    if (user.len == 0) {
        log.warn("ssh -G output missing user", .{});
        return null;
    }
    if (host.len == 0) {
        log.warn("ssh -G output missing hostname", .{});
        return null;
    }

    return std.fmt.allocPrint(alloc, "{s}@{s}", .{ user, host }) catch null;
}

/// Install Ghostty's terminfo on the remote host over a short-lived SSH
/// ControlMaster connection. The master tears down with the client
/// (`ControlPersist=no`) so no socket lingers.
fn installRemoteTerminfo(
    alloc: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
) !void {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try ghostty_terminfo.encode(&buf.writer);
    const terminfo = buf.written();

    // ControlPath is in TMPDIR with a short, random basename. ssh uses
    // ControlPath as the bind address for a Unix domain socket; macOS
    // limits sockaddr_un.sun_path to ~104 bytes, so keeping the path
    // short leaves margin.
    const control_path = try internal_os.randomTmpPath(alloc, "ghostty-ssh-");
    const control_path_opt = try std.fmt.allocPrint(
        alloc,
        "ControlPath={s}",
        .{control_path},
    );

    // Under --verbose, let remote stderr through (the `tic` step is
    // the most common failure source) and inherit ssh's stderr so it
    // reaches the user's terminal. Other steps stay quiet either way.
    const remote_script = if (opts.verbose)
        \\infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
        \\command -v tic >/dev/null 2>&1 || exit 1
        \\mkdir -p ~/.terminfo 2>/dev/null && tic -x - && exit 0
        \\exit 1
    else
        \\infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
        \\command -v tic >/dev/null 2>&1 || exit 1
        \\mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
        \\exit 1
    ;

    // Set up an SSH ControlMaster scoped to this single install:
    //   - ControlMaster=yes makes our client also act as the master,
    //     so `infocmp | ssh tic` runs over a single connection.
    //   - ControlPersist=no tears the master down when our client
    //     exits; no socket lingers on the remote side.
    const argv = try std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        &.{
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", control_path_opt,
        },
        opts._ssh_args.items,
        &.{remote_script},
    });
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

    var child = std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = if (opts.verbose) .inherit else .ignore,
    }) catch |err| {
        log.warn("terminfo install spawn failed: {}", .{err});
        return error.InstallFailed;
    };

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(global.io(), terminfo) catch {};
        stdin.close(global.io());
        child.stdin = null;
    }

    const term = child.wait(global.io()) catch |err| {
        log.warn("terminfo install wait failed: {}", .{err});
        return error.InstallFailed;
    };
    checkExit(term, "terminfo install") catch return error.InstallFailed;
}

/// Returns `128 + signum` for signal-killed children, matching shell convention.
fn childExec(argv: []const []const u8) !u8 {
    var child = try std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(global.io());
    return switch (term) {
        .exited => |rc| rc,
        .signal => |sig| @as(u8, 128) + @as(u8, @intCast(@min(@intFromEnum(sig), 127))),
        .stopped, .unknown => 1,
    };
}

/// ssh options (single-letter) that consume the following argument.
const ssh_opts_with_value = "BbcDEeFIiJLlmOopQRSWw";

/// ssh options (single-letter) that imply no interactive shell, so a
/// persistent session must not be attached.
const ssh_opts_skip = "TNfnGOW";

/// Returns the index of the destination argument if the given ssh
/// arguments describe an interactive login session (a destination with
/// no remote command). Returns null if the session is not interactive
/// or the destination cannot be determined, in which case no persistent
/// session should be used.
fn interactiveDestIdx(args: []const []const u8) ?usize {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // A bare "-" or "--" is not something we understand; be
        // conservative and skip the persistent session.
        if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) return null;

        // The first non-option argument is the destination. ssh runs
        // everything after it as the remote command, so a destination
        // with trailing arguments is not an interactive login.
        if (!std.mem.startsWith(u8, arg, "-")) {
            if (i + 1 < args.len) return null;
            return i;
        }

        // Long options are not used by ssh itself; don't guess.
        if (std.mem.startsWith(u8, arg, "--")) return null;

        // A cluster of single-letter options (e.g. `-vv`). If any
        // option in the cluster takes a value, it consumes the
        // following argument.
        var takes_value = false;
        for (arg[1..]) |c| {
            if (std.mem.indexOfScalar(u8, ssh_opts_skip, c) != null) return null;
            if (std.mem.indexOfScalar(u8, ssh_opts_with_value, c) != null) takes_value = true;
        }
        if (takes_value) i += 1;
    }

    // No destination found.
    return null;
}

/// Returns true if the argument needs no quoting to survive a round
/// trip through a POSIX shell.
fn shellSafe(arg: []const u8) bool {
    if (arg.len == 0) return false;
    for (arg) |c| {
        const safe = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.', '@', '=', '+', ',', ':', '/', '%' => true,
            else => false,
        };
        if (!safe) return false;
    }
    return true;
}

/// Quote an argument for a POSIX shell if necessary.
fn shellQuote(alloc: Allocator, arg: []const u8) ![]const u8 {
    if (shellSafe(arg)) return arg;

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeByte('\'');
    var start: usize = 0;
    for (arg, 0..) |c, i| {
        if (c == '\'') {
            try w.writeAll(arg[start..i]);
            try w.writeAll("'\\''");
            start = i + 1;
        }
    }
    try w.writeAll(arg[start..]);
    try w.writeByte('\'');

    return try buf.toOwnedSlice();
}

/// Write the GhosttyRestoreCommand OSC sequence to the controlling
/// terminal. If `args` is null the restore command is cleared (e.g.
/// after the ssh session exits); otherwise it is set to `ssh <args>`.
/// This is best-effort: any failure is ignored so that it can never
/// break the ssh session itself.
fn writeRestoreCommand(alloc: Allocator, args: ?[]const []const u8) void {
    writeRestoreCommandInner(alloc, args) catch {};
}

fn writeRestoreCommandInner(alloc: Allocator, args_: ?[]const []const u8) !void {
    if (comptime builtin.os.tag == .windows) return;

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("\x1b]1337;GhosttyRestoreCommand=");
    if (args_) |args| {
        try w.writeAll("ssh");
        for (args) |arg| {
            // Refuse to record arguments with control characters; the
            // value is replayed into a shell when the surface is
            // restored.
            for (arg) |c| {
                if (c < 0x20 or c == 0x7f) return;
            }
            try w.writeByte(' ');
            try w.writeAll(try shellQuote(alloc, arg));
        }
    }
    try w.writeByte('\x07');

    var tty = std.Io.Dir.openFileAbsolute(global.io(), "/dev/tty", .{ .mode = .write_only }) catch return;
    defer tty.close(global.io());
    var io_buf: [4096]u8 = undefined;
    var tty_writer = tty.writer(global.io(), &io_buf);
    const iface = &tty_writer.interface;
    iface.writeAll(buf.written()) catch return;
    iface.flush() catch {};
}

fn parseTestArgs(alloc: Allocator, opts: *Options, line: []const u8) !void {
    var iter = try std.process.Args.IteratorGeneral(.{}).init(alloc, line);
    defer iter.deinit();
    try cli_args.parse(Options, alloc, opts, &iter);
}

test "parseManuallyHook: bare destination starts ssh args" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "--terminfo=false user@example.com");
    try testing.expectEqual(false, opts.terminfo);
    try testing.expectEqual(true, opts.@"forward-env");
    try testing.expectEqual(@as(usize, 1), opts._ssh_args.items.len);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[0]);
}

test "parseManuallyHook: short ssh flags pass through verbatim" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "-p 2222 user@example.com");
    try testing.expectEqual(@as(usize, 3), opts._ssh_args.items.len);
    try testing.expectEqualStrings("-p", opts._ssh_args.items[0]);
    try testing.expectEqualStrings("2222", opts._ssh_args.items[1]);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[2]);
}

test "parseManuallyHook: explicit -- separator" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(
        testing.allocator,
        &opts,
        "--verbose -- --some-rare-ssh-arg user@example.com",
    );
    try testing.expectEqual(true, opts.verbose);
    try testing.expectEqual(@as(usize, 2), opts._ssh_args.items.len);
    try testing.expectEqualStrings("--some-rare-ssh-arg", opts._ssh_args.items[0]);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[1]);
}

test "parseDestination: typical ssh -G output" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\user alice
        \\hostname example.com
        \\port 22
        \\identityfile ~/.ssh/id_ed25519
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?);
}

test "parseDestination: hostname before user" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\hostname example.com
        \\port 22
        \\user alice
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?);
}

test "parseDestination: missing hostname returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nport 22\n";
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), stdout));
}

test "parseDestination: missing user returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "hostname example.com\nport 22\n";
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), stdout));
}

test "parseDestination: empty input returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), ""));
}

test "parseDestination: IPv6 hostname" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nhostname ::1\n";
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@::1", result.?);
}

test "interactiveDestIdx: bare destination" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 0), interactiveDestIdx(&.{"user@example.com"}));
}

test "interactiveDestIdx: flags before destination" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 3), interactiveDestIdx(&.{ "-p", "2222", "-v", "user@example.com" }));
}

test "interactiveDestIdx: option cluster with trailing value option" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 2), interactiveDestIdx(&.{ "-vvp", "2222", "user@example.com" }));
}

test "interactiveDestIdx: option with value directly before destination" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 2), interactiveDestIdx(&.{ "-o", "Foo=bar", "user@example.com" }));
}

test "interactiveDestIdx: remote command present" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, null), interactiveDestIdx(&.{ "user@example.com", "uptime" }));
}

test "interactiveDestIdx: -T disables pty allocation" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, null), interactiveDestIdx(&.{ "-T", "user@example.com" }));
}

test "interactiveDestIdx: -N forwarding only" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, null), interactiveDestIdx(&.{ "-N", "-L", "8080:localhost:80", "user@example.com" }));
}

test "interactiveDestIdx: no destination" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, null), interactiveDestIdx(&.{"-v"}));
}

test "interactiveDestIdx: unknown long option" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, null), interactiveDestIdx(&.{ "--something", "user@example.com" }));
}

test "shellQuote: safe arg unchanged" {
    const testing = std.testing;
    const q = try shellQuote(testing.allocator, "user@example.com");
    try testing.expectEqualStrings("user@example.com", q);
}

test "shellQuote: quotes special characters" {
    const testing = std.testing;
    const q = try shellQuote(testing.allocator, "a b");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("'a b'", q);
}

test "shellQuote: escapes embedded single quotes" {
    const testing = std.testing;
    const q = try shellQuote(testing.allocator, "it's");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("'it'\\''s'", q);
}

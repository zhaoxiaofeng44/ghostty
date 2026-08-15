const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const global = @import("../global.zig");
const ptypkg = @import("../pty.zig");
const Pty = ptypkg.Pty;
const Command = @import("../Command.zig");
const xdg = @import("../os/xdg.zig");

const log = std.log.scoped(.persist);

const usage =
    \\Usage: ghostty +persist --server|--attach|--status --session <name> [--] [command...]
    \\
    \\A tiny session helper in the spirit of tmux. The server owns a PTY
    \\running `command` (by default a login shell) so the processes inside
    \\survive the local terminal closing. Attach connects over a Unix
    \\socket, replays recent output, and shuttles bytes both ways.
    \\
    \\Flags:
    \\  --server              Start (or reuse) the persist daemon.
    \\  --attach              Attach to an existing session (starts one if needed).
    \\  --status              Exit 0 if the session socket exists.
    \\  --session=<name>      Session name. Required.
    \\  --restart[=bool]      When the command exits with a lost-connection
    \\                        status (ssh exit 255 or a signal), restart it
    \\                        with backoff instead of ending the session.
    \\                        Default: false.
    \\  --help                Show this help.
    \\
    \\Everything after `--` (or the first non-flag argument) is the command
    \\to run inside the session PTY. No command means a login shell.
    \\
;

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    server: bool = false,
    attach: bool = false,
    status: bool = false,
    session: ?[]const u8 = null,
    restart: bool = false,

    /// Command to run inside the session PTY. Populated by
    /// `parseManuallyHook` from the trailing (non-flag) arguments.
    _command: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(_: Options) !void {
        return Action.help_error;
    }

    /// Manual parse hook. A literal `--` or any non-flag argument starts
    /// the command; it and everything after it is collected verbatim and
    /// flag parsing stops.
    pub fn parseManuallyHook(
        self: *Options,
        alloc: Allocator,
        arg: []const u8,
        iter: anytype,
    ) Allocator.Error!bool {
        if (std.mem.eql(u8, arg, "--")) {
            while (iter.next()) |rest| {
                try self._command.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }

        if (!std.mem.startsWith(u8, arg, "--")) {
            try self._command.append(alloc, try alloc.dupe(u8, arg));
            while (iter.next()) |rest| {
                try self._command.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }

        return true;
    }
};

pub const Frame = struct {
    pub const Kind = enum(u8) {
        data = 0x01,
        winsize = 0x02,
        detach = 0x03,
    };

    pub const header_size = 5;
    pub const max_payload = 64 * 1024;

    kind: Kind,
    payload: []const u8,

    pub fn encode(kind: Kind, payload: []const u8, out: []u8) error{BufferTooSmall}![]const u8 {
        if (out.len < header_size + payload.len) return error.BufferTooSmall;
        out[0] = @intFromEnum(kind);
        std.mem.writeInt(u32, out[1..5], @intCast(payload.len), .little);
        @memcpy(out[header_size..][0..payload.len], payload);
        return out[0 .. header_size + payload.len];
    }

    pub fn decode(buf: []const u8) error{ Incomplete, Invalid }!struct { frame: Frame, used: usize } {
        if (buf.len < header_size) return error.Incomplete;
        if (buf[0] < @intFromEnum(Kind.data) or buf[0] > @intFromEnum(Kind.detach)) {
            return error.Invalid;
        }
        const kind: Kind = @enumFromInt(buf[0]);
        const len = std.mem.readInt(u32, buf[1..5], .little);
        if (len > max_payload) return error.Invalid;
        if (buf.len < header_size + len) return error.Incomplete;
        return .{
            .frame = .{ .kind = kind, .payload = buf[header_size..][0..len] },
            .used = header_size + len,
        };
    }
};

pub const Ring = struct {
    buf: []u8,
    start: usize = 0,
    len: usize = 0,

    pub fn init(storage: []u8) Ring {
        return .{ .buf = storage };
    }

    pub fn write(self: *Ring, data: []const u8) void {
        if (self.buf.len == 0 or data.len == 0) return;
        const incoming = if (data.len > self.buf.len) data[data.len - self.buf.len ..] else data;
        if (incoming.len == self.buf.len) {
            @memcpy(self.buf, incoming);
            self.start = 0;
            self.len = self.buf.len;
            return;
        }
        if (self.len + incoming.len > self.buf.len) {
            const drop = self.len + incoming.len - self.buf.len;
            self.start = (self.start + drop) % self.buf.len;
            self.len -= drop;
        }
        var remaining = incoming;
        while (remaining.len > 0) {
            const dest = (self.start + self.len) % self.buf.len;
            const n = @min(remaining.len, self.buf.len - dest);
            @memcpy(self.buf[dest..][0..n], remaining[0..n]);
            self.len += n;
            remaining = remaining[n..];
        }
    }

    pub fn snapshot(self: Ring, out: []u8) []const u8 {
        const n = @min(self.len, out.len);
        if (n == 0) return out[0..0];
        const first = @min(n, self.buf.len - self.start);
        @memcpy(out[0..first], self.buf[self.start..][0..first]);
        if (first < n) {
            @memcpy(out[first..n], self.buf[0 .. n - first]);
        }
        return out[0..n];
    }
};

pub fn sessionName(alloc: Allocator, dest: []const u8) ![]const u8 {
    var buf = try alloc.alloc(u8, dest.len);
    defer alloc.free(buf);
    for (dest, 0..) |c, i| {
        buf[i] = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => c,
            else => '-',
        };
    }
    return try std.fmt.allocPrint(alloc, "ghostty-{s}", .{buf});
}

/// Persistent PTY session helper, a tiny tmux replacement. The server
/// owns a PTY (running the given command, or a login shell) so the
/// processes inside survive the local terminal closing. Attach connects
/// over a Unix socket and shuttles bytes plus window-size updates.
///
/// Usage: ghostty +persist --server|--attach|--status --session <name> [--] [command...]
pub fn run(alloc_gpa: Allocator) !u8 {
    if (comptime builtin.os.tag == .windows) {
        std.log.err("+persist is not supported on Windows", .{});
        return 1;
    }

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc_gpa, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc_gpa, &opts, &iter);
    }

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file: std.Io.File = .stderr();
    var stderr_writer = stderr_file.writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const modes: u3 = @intFromBool(opts.server) + @intFromBool(opts.attach) + @intFromBool(opts.status);
    if (modes != 1 or opts.session == null or opts.session.?.len == 0) {
        stderr.print("{s}", .{usage}) catch {};
        stderr.flush() catch {};
        return 2;
    }

    const session = opts.session.?;
    const command: []const []const u8 = opts._command.items;
    const socket_path = socketPath(alloc_gpa, session) catch |err| {
        stderr.print("Error: could not resolve persist socket: {t}\n", .{err}) catch {};
        stderr.flush() catch {};
        return 1;
    };
    defer alloc_gpa.free(socket_path);

    const result = if (opts.status)
        status(socket_path)
    else if (opts.server)
        server(alloc_gpa, socket_path, command, opts.restart)
    else
        attach(alloc_gpa, session, socket_path, command, opts.restart);

    stderr.flush() catch {};
    return result;
}

fn status(socket_path: []const u8) u8 {
    std.Io.Dir.cwd().access(global.io(), socket_path, .{}) catch return 1;
    return 0;
}

fn socketPath(alloc: Allocator, session: []const u8) ![]u8 {
    var env_map = try global.environMap();
    defer env_map.deinit();

    const runtime = env_map.get("XDG_RUNTIME_DIR");
    const base = if (runtime) |dir|
        try std.fmt.allocPrint(alloc, "{s}/ghostty/persist", .{dir})
    else
        try xdg.cache(global.io(), alloc, &env_map, .{ .subdir = "ghostty/persist" });
    defer if (runtime != null) alloc.free(base);

    try std.Io.Dir.cwd().createDirPath(global.io(), base);
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.sock", .{ base, session });
    if (path.len >= 100) return error.SocketPathTooLong;
    return path;
}

/// How the session child exited.
const ChildExit = struct {
    /// The exit code. Only meaningful when `signaled` is false.
    code: u8,

    /// True when the child was killed by a signal.
    signaled: bool,

    /// True when the exit looks like a lost connection rather than a
    /// deliberate exit. ssh uses exit code 255 for connection errors
    /// (network loss, sshd restart, host reboot); a normal remote shell
    /// exit propagates 0 (or the shell's own status).
    fn restartable(self: ChildExit) bool {
        return self.signaled or self.code == 255;
    }
};

fn exitFromStatus(wait_status: u32) ChildExit {
    const exited = posix.system.W.IFEXITED(wait_status);
    return .{
        .code = if (exited) posix.system.W.EXITSTATUS(wait_status) else 0,
        .signaled = !exited,
    };
}

/// Non-blocking reap of the session child. Returns how it exited (and
/// reaps it), or null when it is still running.
fn waitPidExit(pid: posix.pid_t) ?ChildExit {
    var wait_status: if (builtin.link_libc) c_int else u32 = 0;
    const rc = posix.system.waitpid(pid, &wait_status, posix.system.W.NOHANG);
    if (rc <= 0) return null;
    return exitFromStatus(@bitCast(wait_status));
}

/// Delay before reconnecting after the nth consecutive failure. Grows
/// exponentially from 1s up to a 30s cap.
fn reconnectDelayMs(attempts: usize) u32 {
    const shift: u5 = @intCast(@min(attempts - 1, 5));
    return @min(@as(u32, 1000) << shift, 30_000);
}

fn nowSeconds() i64 {
    return std.Io.Timestamp.now(global.io(), .real).toSeconds();
}

fn server(gpa: Allocator, socket_path: []const u8, command: []const []const u8, restart: bool) !u8 {
    ignoreSigpipe();

    if (std.Io.Dir.cwd().access(global.io(), socket_path, .{})) |_| {
        return 0;
    } else |_| {}

    // Daemonize before spawning the child so that the daemon is the
    // child's real parent and can reap it to observe its exit status.
    daemonize() catch |err| {
        log.warn("failed to daemonize persist server: {t}", .{err});
    };

    const listen_fd = try listenUnix(socket_path);
    defer {
        closeFd(listen_fd);
        std.Io.Dir.cwd().deleteFile(global.io(), socket_path) catch {};
    }

    var pty = try Pty.open(.{ .ws_row = 24, .ws_col = 80 });
    var cmd = try ptyCommand(gpa, &pty, command);
    try cmd.start(gpa);
    // Close the slave in the daemon so only the child holds it.
    closeFd(pty.slave);
    defer closeFd(pty.master);

    // Reset the reconnect backoff once the session has been up for a
    // while, so a healthy connection doesn't inherit old failures.
    var spawned_at = nowSeconds();
    var attempts: usize = 0;

    var ring_storage: [256 * 1024]u8 = undefined;
    var ring = Ring.init(&ring_storage);
    var client_fd: ?posix.fd_t = null;
    var read_buf: [4096]u8 = undefined;
    var client_acc: std.ArrayList(u8) = .empty;
    defer client_acc.deinit(gpa);

    // A child exit observed but not yet handled. Handling either
    // reconnects (replacing pty/cmd) or ends the session.
    var pending_exit: ?ChildExit = null;

    while (true) {
        if (pending_exit == null) {
            if (cmd.pid) |pid| pending_exit = waitPidExit(pid);
        }
        if (pending_exit) |exit| {
            pending_exit = null;
            if (!restart or !exit.restartable()) break;

            if (nowSeconds() - spawned_at >= 10) attempts = 0;
            attempts += 1;

            const msg = "\r\n\x1b[33m[ghostty] connection lost; reconnecting...\x1b[0m\r\n";
            ring.write(msg);
            if (client_fd) |fd| writeFrame(fd, .data, msg) catch {
                closeFd(fd);
                client_fd = null;
            };
            std.Io.sleep(global.io(), .fromMilliseconds(reconnectDelayMs(attempts)), .awake) catch {};

            closeFd(pty.master);
            pty = Pty.open(.{ .ws_row = 24, .ws_col = 80 }) catch break;
            cmd = ptyCommand(gpa, &pty, command) catch break;
            cmd.start(gpa) catch break;
            closeFd(pty.slave);
            spawned_at = nowSeconds();
            continue;
        }

        var fds = [_]posix.pollfd{
            .{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = client_fd orelse -1, .events = posix.POLL.IN, .revents = 0 },
        };
        const nfd: usize = if (client_fd != null) 3 else 2;
        _ = posix.poll(fds[0..nfd], 250) catch continue;

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(pty.master, &read_buf) catch 0;
            if (n == 0) {
                // The child side of the pty is gone. Give the child a
                // moment to be reaped so we know why it died; if it is
                // still alive (e.g. it closed its fds) the session ends.
                var tries: usize = 0;
                while (tries < 10) : (tries += 1) {
                    if (cmd.pid) |pid| {
                        if (waitPidExit(pid)) |exit| {
                            pending_exit = exit;
                            break;
                        }
                    }
                    std.Io.sleep(global.io(), .fromMilliseconds(50), .awake) catch {};
                }
                if (pending_exit == null) break;
                continue;
            }
            ring.write(read_buf[0..n]);
            if (client_fd) |fd| {
                writeFrame(fd, .data, read_buf[0..n]) catch {
                    closeFd(fd);
                    client_fd = null;
                };
            }
        }

        if (fds[1].revents & posix.POLL.IN != 0) {
            const new_fd = acceptUnix(listen_fd) catch continue;
            if (client_fd) |old| closeFd(old);
            client_fd = new_fd;
            client_acc.clearRetainingCapacity();
            replayRing(&ring, new_fd) catch {
                closeFd(new_fd);
                client_fd = null;
            };

            // The poll table still refers to the old client fd; rebuild
            // it before touching the new client.
            continue;
        }

        if (client_fd != null and fds[2].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
            const fd = client_fd.?;
            if (fds[2].revents & posix.POLL.IN != 0) {
                const n = posix.read(fd, &read_buf) catch 0;
                if (n == 0) {
                    closeFd(fd);
                    client_fd = null;
                    continue;
                }
                try client_acc.appendSlice(gpa, read_buf[0..n]);
                consumeClientFrames(gpa, &client_acc, &pty, fd) catch {
                    closeFd(fd);
                    client_fd = null;
                };
            } else {
                closeFd(fd);
                client_fd = null;
            }
        }
    }

    return 0;
}

/// Build the Command that runs inside the session PTY. With no command
/// a login shell is used. The returned command borrows `pty`, which must
/// outlive the child.
fn ptyCommand(gpa: Allocator, pty: *Pty, command: []const []const u8) !Command {
    var cmd_path: [:0]const u8 = undefined;
    var cmd_args: []const [:0]const u8 = undefined;
    if (command.len == 0) {
        const shell = global.environ().getPosix("SHELL") orelse "/bin/sh";
        cmd_path = try gpa.dupeZ(u8, shell);
        cmd_args = &.{ cmd_path, "-l" };
    } else {
        cmd_path = try gpa.dupeZ(u8, command[0]);
        const argv = try gpa.alloc([:0]const u8, command.len);
        for (command, 0..) |arg, i| argv[i] = try gpa.dupeZ(u8, arg);
        cmd_args = argv;
    }

    return .{
        .path = cmd_path,
        .args = cmd_args,
        .stdin = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } },
        .stdout = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } },
        .stderr = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } },
        .os_pre_exec = struct {
            fn callback(c: *Command) ?u8 {
                const persist_pty = c.getData(Pty) orelse return 1;
                persist_pty.childPreExec() catch return 1;
                return null;
            }
        }.callback,
        .rt_pre_exec = null,
        .rt_pre_exec_info = .init(undefined),
        .rt_post_fork = null,
        .rt_post_fork_info = .init(undefined),
        .data = pty,
    };
}

/// Writing to a socket whose peer went away must not kill the daemon;
/// write errors are handled at the call site instead.
fn ignoreSigpipe() void {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sa, null);
}

fn consumeClientFrames(
    gpa: Allocator,
    acc: *std.ArrayList(u8),
    pty: *Pty,
    client_fd: posix.fd_t,
) !void {
    _ = gpa;
    _ = client_fd;
    var rest = acc.items;
    while (true) {
        const decoded = Frame.decode(rest) catch |err| switch (err) {
            error.Incomplete => break,
            error.Invalid => return error.Invalid,
        };
        switch (decoded.frame.kind) {
            .data => writeAll(pty.master, decoded.frame.payload) catch {},
            .winsize => if (decoded.frame.payload.len == 8) {
                const size = ptypkg.winsize{
                    .ws_row = std.mem.readInt(u16, decoded.frame.payload[0..2], .little),
                    .ws_col = std.mem.readInt(u16, decoded.frame.payload[2..4], .little),
                    .ws_xpixel = std.mem.readInt(u16, decoded.frame.payload[4..6], .little),
                    .ws_ypixel = std.mem.readInt(u16, decoded.frame.payload[6..8], .little),
                };
                pty.setSize(size) catch {};
            },
            .detach => {},
        }
        rest = rest[decoded.used..];
    }
    const consumed = acc.items.len - rest.len;
    if (consumed > 0) acc.replaceRangeAssumeCapacity(0, consumed, &.{});
}

fn replayRing(ring: *const Ring, fd: posix.fd_t) !void {
    var buf: [256 * 1024]u8 = undefined;
    const data = ring.snapshot(&buf);
    // Frames larger than max_payload are rejected by the decoder, so the
    // replay is sent in chunks.
    var rest = data;
    while (rest.len > 0) {
        const n = @min(rest.len, Frame.max_payload);
        try writeFrame(fd, .data, rest[0..n]);
        rest = rest[n..];
    }
}

/// Attach to the persist session `session`, starting the server with
/// `command` in the PTY if it isn't running yet. When `restart` is true
/// the server restarts the command after a lost-connection exit instead
/// of ending the session. This is the entry point used by
/// `ghostty +ssh --persist` so the ssh process (and the remote processes
/// behind it) survive the local terminal closing.
pub fn attachCommand(
    gpa: Allocator,
    session: []const u8,
    command: []const []const u8,
    restart: bool,
) !u8 {
    const socket_path = socketPath(gpa, session) catch |err| {
        log.warn("could not resolve persist socket: {t}", .{err});
        return 1;
    };
    defer gpa.free(socket_path);
    return attach(gpa, session, socket_path, command, restart);
}

fn attach(
    gpa: Allocator,
    session: []const u8,
    socket_path: []const u8,
    command: []const []const u8,
    restart: bool,
) !u8 {
    ignoreSigpipe();

    if (status(socket_path) != 0) {
        startServer(gpa, session, command, restart) catch |err| {
            log.warn("failed to start persist server: {t}", .{err});
            return 1;
        };
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            if (status(socket_path) == 0) break;
            std.Io.sleep(global.io(), .fromMilliseconds(20), .awake) catch {};
        }
        if (status(socket_path) != 0) return 1;
    }

    const fd = try connectUnix(socket_path);
    defer closeFd(fd);

    sendCurrentWinsize(fd);

    var stdin_termios_saved: ?posix.termios = null;
    if (posix.system.isatty(posix.STDIN_FILENO) != 0) {
        if (posix.tcgetattr(posix.STDIN_FILENO)) |old| {
            stdin_termios_saved = old;
            var raw = old;
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false;
            posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch {};
        } else |_| {}
    }
    defer if (stdin_termios_saved) |old| {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, old) catch {};
    };

    var winch = std.atomic.Value(bool).init(false);
    const handler = struct {
        var flag: *std.atomic.Value(bool) = undefined;
        fn onWinch(_: posix.SIG) callconv(.c) void {
            flag.store(true, .release);
        }
    };
    handler.flag = &winch;
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = handler.onWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);

    var read_buf: [4096]u8 = undefined;
    var sock_acc: std.ArrayList(u8) = .empty;
    defer sock_acc.deinit(gpa);

    // Reading EOF on stdin (e.g. a closed pipe) does not detach the
    // session; like ssh we simply stop forwarding input and keep
    // printing output until the session ends.
    var stdin_open = true;

    while (true) {
        if (winch.swap(false, .acq_rel)) sendCurrentWinsize(fd);

        var fds = [_]posix.pollfd{
            .{ .fd = if (stdin_open) posix.STDIN_FILENO else -1, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, 250) catch continue;

        if (stdin_open and fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(posix.STDIN_FILENO, &read_buf) catch {
                stdin_open = false;
                continue;
            };
            if (n == 0) {
                stdin_open = false;
            } else {
                writeFrame(fd, .data, read_buf[0..n]) catch break;
            }
        }

        if (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
            if (fds[1].revents & posix.POLL.IN == 0) break;
            const n = posix.read(fd, &read_buf) catch break;
            if (n == 0) break;
            try sock_acc.appendSlice(gpa, read_buf[0..n]);
            var rest = sock_acc.items;
            while (true) {
                const decoded = Frame.decode(rest) catch |err| switch (err) {
                    error.Incomplete => break,
                    error.Invalid => return 1,
                };
                if (decoded.frame.kind == .data) {
                    writeAll(posix.STDOUT_FILENO, decoded.frame.payload) catch {};
                }
                rest = rest[decoded.used..];
            }
            const consumed = sock_acc.items.len - rest.len;
            if (consumed > 0) sock_acc.replaceRangeAssumeCapacity(0, consumed, &.{});
        }
    }

    return 0;
}

fn startServer(
    gpa: Allocator,
    session: []const u8,
    command: []const []const u8,
    restart: bool,
) !void {
    // Re-exec ourselves (argv0) to run the server. Windows and WASI never
    // reach this code (see run).
    const exe: [:0]const u8 = if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi)
        "ghostty"
    else
        try gpa.dupeZ(u8, std.mem.span(global.args().vector[0]));
    defer gpa.free(exe);
    const session_flag = try std.fmt.allocPrint(gpa, "--session={s}", .{session});
    defer gpa.free(session_flag);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    if (restart) {
        try argv.appendSlice(gpa, &.{ exe, "+persist", "--server", "--restart", session_flag, "--" });
    } else {
        try argv.appendSlice(gpa, &.{ exe, "+persist", "--server", session_flag, "--" });
    }
    try argv.appendSlice(gpa, command);
    const child = try std.process.spawn(global.io(), .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = child;
}

fn sendCurrentWinsize(fd: posix.fd_t) void {
    var ws: ptypkg.winsize = .{};
    const c = @cImport({
        @cInclude("sys/ioctl.h");
    });
    if (c.ioctl(posix.STDIN_FILENO, c.TIOCGWINSZ, @intFromPtr(&ws)) < 0) return;
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], ws.ws_row, .little);
    std.mem.writeInt(u16, payload[2..4], ws.ws_col, .little);
    std.mem.writeInt(u16, payload[4..6], ws.ws_xpixel, .little);
    std.mem.writeInt(u16, payload[6..8], ws.ws_ypixel, .little);
    writeFrame(fd, .winsize, &payload) catch {};
}

fn writeFrame(fd: posix.fd_t, kind: Frame.Kind, payload: []const u8) !void {
    var hdr: [Frame.header_size]u8 = undefined;
    hdr[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
    try writeAll(fd, &hdr);
    try writeAll(fd, payload);
}

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var rest = data;
    while (rest.len > 0) {
        const rc = posix.system.write(fd, rest.ptr, rest.len);
        if (rc <= 0) return error.BrokenPipe;
        rest = rest[@intCast(rc)..];
    }
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

fn unixSocketAddress(path: []const u8) !posix.sockaddr.un {
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (path.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

fn acceptUnix(listen_fd: posix.fd_t) !posix.fd_t {
    const rc = posix.system.accept(listen_fd, null, null);
    if (rc < 0) return error.AcceptFailed;
    return @intCast(rc);
}

fn listenUnix(path: []const u8) !posix.fd_t {
    // SOCK.CLOEXEC is a Zig-only shim value on Darwin, so it can't be
    // passed to the libc socket() call directly.
    const fd = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer closeFd(fd);

    var addr = try unixSocketAddress(path);
    if (posix.system.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) {
        // A leftover socket file from a crashed server keeps the address
        // busy. Remove it and try once more; if a live server is holding
        // it, the second bind fails too and we propagate the error.
        std.Io.Dir.cwd().deleteFile(global.io(), path) catch {};
        if (posix.system.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) {
            return error.AddressInUse;
        }
    }
    if (posix.system.listen(fd, 1) != 0) return error.ListenFailed;
    return @intCast(fd);
}

fn connectUnix(path: []const u8) !posix.fd_t {
    const fd = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer closeFd(fd);
    var addr = try unixSocketAddress(path);
    if (posix.system.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) {
        return error.ConnectionRefused;
    }
    return @intCast(fd);
}

fn daemonize() !void {
    const pid = posix.system.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid > 0) posix.system.exit(0);
    _ = posix.system.setsid();
    const pid2 = posix.system.fork();
    if (pid2 < 0) return error.ForkFailed;
    if (pid2 > 0) posix.system.exit(0);

    // Detach from the caller's terminal but keep fds 0-2 open on
    // /dev/null. If they were closed, a later open (e.g. the session
    // pty) could claim fd 0-2 and confuse the child's stdio setup.
    const devnull = posix.system.open(
        "/dev/null",
        posix.O{ .ACCMODE = .RDWR },
        @as(c_uint, 0),
    );
    if (devnull >= 0) {
        _ = posix.system.dup2(devnull, posix.STDIN_FILENO);
        _ = posix.system.dup2(devnull, posix.STDOUT_FILENO);
        _ = posix.system.dup2(devnull, posix.STDERR_FILENO);
        if (devnull > posix.STDERR_FILENO) closeFd(devnull);
    }
}

test "frame encode decode" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;
    const encoded = try Frame.encode(.data, "hi", &buf);
    const decoded = try Frame.decode(encoded);
    try testing.expectEqual(Frame.Kind.data, decoded.frame.kind);
    try testing.expectEqualStrings("hi", decoded.frame.payload);
    try testing.expectEqual(encoded.len, decoded.used);
}

test "ring wraps and keeps newest" {
    const testing = std.testing;
    var storage: [4]u8 = undefined;
    var ring = Ring.init(&storage);
    ring.write("abcd");
    ring.write("ef");
    var out: [8]u8 = undefined;
    try testing.expectEqualStrings("cdef", ring.snapshot(&out));
}

test "session name sanitizes dest" {
    const testing = std.testing;
    const name = try sessionName(testing.allocator, "alice@ex.com");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("ghostty-alice-ex-com", name);
}

test "reconnectDelayMs grows exponentially and caps at 30s" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 1000), reconnectDelayMs(1));
    try testing.expectEqual(@as(u32, 2000), reconnectDelayMs(2));
    try testing.expectEqual(@as(u32, 4000), reconnectDelayMs(3));
    try testing.expectEqual(@as(u32, 30_000), reconnectDelayMs(20));
}

test "ChildExit restartable only for ssh errors and signals" {
    const testing = std.testing;
    try testing.expect((ChildExit{ .code = 255, .signaled = false }).restartable());
    try testing.expect((ChildExit{ .code = 0, .signaled = true }).restartable());
    try testing.expect(!(ChildExit{ .code = 0, .signaled = false }).restartable());
    try testing.expect(!(ChildExit{ .code = 1, .signaled = false }).restartable());
}

//! The process's standard streams on every native target: whether each is a
//! terminal, and polling and reading standard input. POSIX uses the file
//! descriptors directly; Windows goes through `windows_console.zig`.

const std = @import("std");
const builtin = @import("builtin");
const windows_console = @import("windows_console.zig");

const is_windows = builtin.target.os.tag == .windows;

pub const Stream = enum { stdin, stdout, stderr };

pub fn handle(stream: Stream) std.posix.fd_t {
    if (comptime is_windows) return switch (stream) {
        .stdin => windows_console.stdinHandle(),
        .stdout => windows_console.stdoutHandle(),
        .stderr => windows_console.stderrHandle(),
    };
    return switch (stream) {
        .stdin => std.posix.STDIN_FILENO,
        .stdout => std.posix.STDOUT_FILENO,
        .stderr => std.posix.STDERR_FILENO,
    };
}

/// A comptime-known stand-in for standard output, for struct defaults: on
/// Windows the handle is only known at run time. Pass such a file through
/// `resolveStdout` before writing to it.
pub const default_stdout: std.Io.File = if (is_windows)
    .{ .handle = std.os.windows.INVALID_HANDLE_VALUE, .flags = .{ .nonblocking = false } }
else
    std.Io.File.stdout();

pub fn resolveStdout(file: std.Io.File) std.Io.File {
    if (comptime is_windows) {
        if (file.handle == std.os.windows.INVALID_HANDLE_VALUE) return std.Io.File.stdout();
    }
    return file;
}

pub fn isTty(stream: Stream) bool {
    if (comptime is_windows) return windows_console.isConsole(handle(stream));
    return std.c.isatty(handle(stream)) != 0;
}

pub const Poll = struct {
    readable: bool = false,
    hung_up: bool = false,
};

/// Waits up to `timeout_ms` (negative waits forever) for standard input.
pub fn pollStdin(timeout_ms: i32) !Poll {
    if (comptime is_windows) {
        const result = windows_console.pollInput(handle(.stdin), timeout_ms);
        return .{ .readable = result.readable, .hung_up = result.hung_up };
    }
    var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&fds, timeout_ms);
    return .{
        .readable = fds[0].revents & std.posix.POLL.IN != 0,
        .hung_up = fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0,
    };
}

/// Reads standard input. A Windows console delivers UTF-8.
pub fn readStdin(out: []u8) !usize {
    if (comptime is_windows) return windows_console.read(handle(.stdin), out);
    return std.posix.read(std.posix.STDIN_FILENO, out);
}

/// What a raw-mode prompt saves and restores.
pub const SavedMode = if (is_windows) windows_console.Saved else std.posix.termios;

/// Raw mode on Windows: keys arrive one at a time with no echo, and Ctrl+C
/// is a byte. POSIX callers keep their own termios settings.
pub fn enterRawWindows() !SavedMode {
    return windows_console.enterRaw(handle(.stdin), handle(.stdout));
}

pub fn restoreWindows(saved: SavedMode) void {
    windows_console.restore(handle(.stdin), handle(.stdout), saved);
}

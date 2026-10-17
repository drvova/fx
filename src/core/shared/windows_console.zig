//! The Windows console as a VT terminal.
//!
//! Windows 10 1809 and later consoles, including Windows Terminal, translate
//! keys into the same VT byte sequences a Unix terminal sends and interpret VT
//! output, so fx's renderer and input parser run unchanged once the console is
//! in that mode. This file holds the few console calls that stand in for
//! termios, `isatty`, `poll`, `TIOCGWINSZ`, and `SIGWINCH`.
//!
//! Every function compiles on every target, and is only called on Windows.

const std = @import("std");
const io_mod = @import("io.zig");

const BOOL = i32;
const DWORD = u32;
const WORD = u16;
const SHORT = i16;
const HANDLE = *anyopaque;

const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
const ENABLE_LINE_INPUT: DWORD = 0x0002;
const ENABLE_ECHO_INPUT: DWORD = 0x0004;
const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
const ENABLE_QUICK_EDIT_MODE: DWORD = 0x0040;
const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;
const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;

const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;

const KEY_EVENT: WORD = 0x0001;
const WINDOW_BUFFER_SIZE_EVENT: WORD = 0x0004;

const WAIT_OBJECT_0: DWORD = 0x0000_0000;
const WAIT_TIMEOUT: DWORD = 0x0000_0102;
const INFINITE: DWORD = 0xFFFF_FFFF;

const FILE_TYPE_CHAR: DWORD = 0x0002;
const FILE_TYPE_PIPE: DWORD = 0x0003;

const CP_UTF8: u32 = 65001;

const COORD = extern struct { X: SHORT, Y: SHORT };
const SMALL_RECT = extern struct { Left: SHORT, Top: SHORT, Right: SHORT, Bottom: SHORT };
const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

const KEY_EVENT_RECORD = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: WORD,
    wVirtualKeyCode: WORD,
    wVirtualScanCode: WORD,
    uChar: extern union { UnicodeChar: u16, AsciiChar: u8 },
    dwControlKeyState: DWORD,
};

const INPUT_RECORD = extern struct {
    EventType: WORD,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        WindowBufferSizeEvent: extern struct { dwSize: COORD },
        padding: [16]u8,
    },
};

extern "kernel32" fn GetConsoleMode(console: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleMode(console: HANDLE, mode: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
extern "kernel32" fn SetConsoleCP(code_page: u32) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(console: HANDLE, info: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, millis: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn PeekConsoleInputW(console: HANDLE, buffer: [*]INPUT_RECORD, len: DWORD, read: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ReadConsoleInputW(console: HANDLE, buffer: [*]INPUT_RECORD, len: DWORD, read: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ReadConsoleW(console: HANDLE, buffer: [*]u16, len: DWORD, read: *DWORD, control: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(file: HANDLE, buffer: [*]u8, len: DWORD, read: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn PeekNamedPipe(pipe: HANDLE, buffer: ?[*]u8, len: DWORD, read: ?*DWORD, available: ?*DWORD, left: ?*DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileType(file: HANDLE) callconv(.winapi) DWORD;

/// What `enterRaw` changed, so `restore` can put it back.
pub const Saved = struct {
    input_mode: DWORD = 0,
    output_mode: DWORD = 0,
    input_cp: u32 = 0,
    output_cp: u32 = 0,
    has_output: bool = false,
};

pub fn stdinHandle() HANDLE {
    return std.Io.File.stdin().handle;
}

pub fn stdoutHandle() HANDLE {
    return std.Io.File.stdout().handle;
}

pub fn stderrHandle() HANDLE {
    return std.Io.File.stderr().handle;
}

/// Whether `handle` is a console, the Windows counterpart of `isatty`.
pub fn isConsole(handle: HANDLE) bool {
    var mode: DWORD = 0;
    return GetConsoleMode(handle, &mode) != 0;
}

extern "c" fn atexit(callback: *const fn () callconv(.c) void) c_int;

var startup_output_cp: u32 = 0;

fn restoreStartupOutputCodePage() callconv(.c) void {
    if (startup_output_cp != 0) _ = SetConsoleOutputCP(startup_output_cp);
}

/// Makes the console display fx's UTF-8 output and VT styling. The console
/// is shared with the shell that started fx, so the code page is put back
/// when the process exits through libc `exit`.
pub fn prepareOutput() void {
    if (isConsole(stdoutHandle())) enableVtOutput(stdoutHandle());
    if (isConsole(stderrHandle())) enableVtOutput(stderrHandle());
}

/// Turns on VT output on `output` without touching input, for commands that
/// print styled text but do not read keys.
pub fn enableVtOutput(output: HANDLE) void {
    var mode: DWORD = 0;
    if (GetConsoleMode(output, &mode) == 0) return;
    _ = SetConsoleMode(output, mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    if (startup_output_cp == 0) {
        startup_output_cp = GetConsoleOutputCP();
        _ = atexit(restoreStartupOutputCodePage);
    }
    _ = SetConsoleOutputCP(CP_UTF8);
}

/// Puts the console in raw VT mode: no line editing, echo, or Ctrl+C
/// processing, keys arrive as VT sequences, and output interprets VT.
pub fn enterRaw(input: HANDLE, output: HANDLE) !Saved {
    var saved: Saved = .{};
    if (GetConsoleMode(input, &saved.input_mode) == 0) return error.NotATerminal;
    saved.input_cp = GetConsoleCP();
    saved.output_cp = GetConsoleOutputCP();
    saved.has_output = GetConsoleMode(output, &saved.output_mode) != 0;

    const raw_input = (saved.input_mode &
        ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_MOUSE_INPUT | ENABLE_QUICK_EDIT_MODE)) |
        ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS;
    if (SetConsoleMode(input, raw_input) == 0) return error.VirtualTerminalUnsupported;
    if (saved.has_output) {
        const vt_output = saved.output_mode | ENABLE_PROCESSED_OUTPUT |
            ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN;
        if (SetConsoleMode(output, vt_output) == 0) {
            _ = SetConsoleMode(input, saved.input_mode);
            return error.VirtualTerminalUnsupported;
        }
    }
    _ = SetConsoleCP(CP_UTF8);
    _ = SetConsoleOutputCP(CP_UTF8);
    return saved;
}

pub fn restore(input: HANDLE, output: HANDLE, saved: Saved) void {
    _ = SetConsoleMode(input, saved.input_mode);
    if (saved.has_output) _ = SetConsoleMode(output, saved.output_mode);
    if (saved.input_cp != 0) _ = SetConsoleCP(saved.input_cp);
    if (saved.output_cp != 0) _ = SetConsoleOutputCP(saved.output_cp);
}

/// The visible window size in cells.
pub fn windowSize(output: HANDLE) !struct { rows: u16, cols: u16 } {
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (GetConsoleScreenBufferInfo(output, &info) == 0) return error.UnableToReadTerminalSize;
    const rows = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
    const cols = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
    if (rows <= 0 or cols <= 0) return error.UnableToReadTerminalSize;
    return .{ .rows = @intCast(rows), .cols = @intCast(cols) };
}

pub const ResizeCallback = *const fn (i32) callconv(.c) void;

/// Set by the interactive shell; called when the console reports a resize,
/// in place of a `SIGWINCH` handler.
pub var resize_callback: ?ResizeCallback = null;

/// The window size `pollInput` last saw, packed as rows << 16 | cols.
var last_window_size: u32 = 0;

/// Calls `resize_callback` when the window size changed since the last
/// check. Conhost queues a resize record only when the buffer changes, and
/// a window that only grows taller can keep its buffer, so `pollInput` also
/// compares the size itself.
fn noteWindowSize() void {
    const callback = resize_callback orelse return;
    const size = windowSize(stdoutHandle()) catch return;
    const packed_size = @as(u32, size.rows) << 16 | size.cols;
    if (packed_size == last_window_size) return;
    const first = last_window_size == 0;
    last_window_size = packed_size;
    if (!first) callback(0);
}

pub const Poll = struct { readable: bool = false, hung_up: bool = false };

/// Waits up to `timeout_ms` (negative waits forever) for input `read` can
/// return without blocking.
pub fn pollInput(input: HANDLE, timeout_ms: i32) Poll {
    return switch (GetFileType(input)) {
        FILE_TYPE_CHAR => pollConsole(input, timeout_ms),
        FILE_TYPE_PIPE => pollPipe(input, timeout_ms),
        // Files and other handles never block.
        else => .{ .readable = true },
    };
}

fn pollPipe(input: HANDLE, timeout_ms: i32) Poll {
    // Anonymous pipes cannot be waited on, so check in short steps.
    var waited: i64 = 0;
    while (true) {
        var available: DWORD = 0;
        if (PeekNamedPipe(input, null, 0, null, &available, null) == 0) return .{ .hung_up = true };
        if (available > 0) return .{ .readable = true };
        if (timeout_ms >= 0 and waited >= timeout_ms) return .{};
        io_mod.sleep(5 * std.time.ns_per_ms);
        waited += 5;
    }
}

fn pollConsole(input: HANDLE, timeout_ms: i32) Poll {
    noteWindowSize();
    if (pending_len > 0) return .{ .readable = true };
    const deadline: ?i64 = if (timeout_ms < 0) null else io_mod.milliTimestamp() + timeout_ms;
    while (true) {
        if (consumeUntilKey(input)) return .{ .readable = true };
        const remaining: DWORD = if (deadline) |d| blk: {
            const left = d - io_mod.milliTimestamp();
            if (left <= 0) return .{};
            break :blk @intCast(left);
        } else INFINITE;
        // Wake at least every 250 ms to notice a resize no record reports.
        switch (WaitForSingleObject(input, @min(remaining, 250))) {
            WAIT_OBJECT_0 => {},
            WAIT_TIMEOUT => {
                noteWindowSize();
                if (remaining <= 250) return .{};
            },
            else => return .{ .hung_up = true },
        }
    }
}

/// Removes queued records that `ReadConsoleW` would not return as text, and
/// reports a pending resize. Returns true when input is ready: a key that
/// produces text is next in the queue, or a navigation key was translated
/// into `pending`.
fn consumeUntilKey(input: HANDLE) bool {
    var record: [1]INPUT_RECORD = undefined;
    while (true) {
        var count: DWORD = 0;
        if (PeekConsoleInputW(input, &record, 1, &count) == 0 or count == 0) return false;
        const event = record[0];
        const key_down = event.EventType == KEY_EVENT and event.Event.KeyEvent.bKeyDown != 0;
        if (key_down and event.Event.KeyEvent.uChar.UnicodeChar != 0) return true;
        _ = ReadConsoleInputW(input, &record, 1, &count);
        if (event.EventType == WINDOW_BUFFER_SIZE_EVENT) noteWindowSize();
        if (key_down) {
            const key = event.Event.KeyEvent;
            const len = translateKey(key.wVirtualKeyCode, key.dwControlKeyState, pending[pending_len..]);
            if (len > 0) {
                pending_len += len;
                return true;
            }
        }
    }
}

const SHIFT_PRESSED: DWORD = 0x0010;
const LEFT_ALT_PRESSED: DWORD = 0x0002;
const RIGHT_ALT_PRESSED: DWORD = 0x0001;
const LEFT_CTRL_PRESSED: DWORD = 0x0008;
const RIGHT_CTRL_PRESSED: DWORD = 0x0004;

/// The xterm sequence for a key that has no text, for consoles that report
/// keys as virtual-key records instead of honoring
/// `ENABLE_VIRTUAL_TERMINAL_INPUT`. Writes nothing for other keys.
fn translateKey(virtual_key: WORD, control_state: DWORD, out: []u8) usize {
    const Final = struct { tilde: bool, code: u8 };
    const final: Final = switch (virtual_key) {
        0x26 => .{ .tilde = false, .code = 'A' }, // VK_UP
        0x28 => .{ .tilde = false, .code = 'B' }, // VK_DOWN
        0x27 => .{ .tilde = false, .code = 'C' }, // VK_RIGHT
        0x25 => .{ .tilde = false, .code = 'D' }, // VK_LEFT
        0x24 => .{ .tilde = false, .code = 'H' }, // VK_HOME
        0x23 => .{ .tilde = false, .code = 'F' }, // VK_END
        0x2D => .{ .tilde = true, .code = 2 }, // VK_INSERT
        0x2E => .{ .tilde = true, .code = 3 }, // VK_DELETE
        0x21 => .{ .tilde = true, .code = 5 }, // VK_PRIOR
        0x22 => .{ .tilde = true, .code = 6 }, // VK_NEXT
        else => return 0,
    };
    var modifier: u8 = 1;
    if (control_state & SHIFT_PRESSED != 0) modifier += 1;
    if (control_state & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED) != 0) modifier += 2;
    if (control_state & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED) != 0) modifier += 4;
    const text = if (final.tilde)
        if (modifier == 1)
            std.mem.print(out, "\x1b[{d}~", .{final.code})
        else
            std.mem.print(out, "\x1b[{d};{d}~", .{ final.code, modifier })
    else if (modifier == 1)
        std.mem.print(out, "\x1b[{c}", .{final.code})
    else
        std.mem.print(out, "\x1b[1;{d}{c}", .{ modifier, final.code });
    return (text catch return 0).len;
}

/// UTF-8 bytes decoded from the console that a short `read` could not
/// return yet. The console input queue is per process, so this is too.
var pending: [1024]u8 = undefined;
var pending_len: usize = 0;

/// Reads input as UTF-8. Blocks until at least one byte is available unless
/// `pollInput` said input was ready.
pub fn read(input: HANDLE, out: []u8) !usize {
    if (out.len == 0) return 0;
    if (pending_len == 0) {
        if (GetFileType(input) != FILE_TYPE_CHAR) {
            var count: DWORD = 0;
            const len: DWORD = @intCast(@min(out.len, std.math.maxInt(DWORD)));
            if (ReadFile(input, out.ptr, len, &count, null) == 0) return 0;
            return count;
        }
        // At most three UTF-8 bytes per UTF-16 unit, so this fills `pending`.
        var wide: [pending.len / 3]u16 = undefined;
        var count: DWORD = 0;
        if (ReadConsoleW(input, &wide, wide.len - 1, &count, null) == 0) return error.InputOutput;
        // A lone high surrogate needs its partner before it can be encoded.
        if (count > 0 and std.unicode.utf16IsHighSurrogate(wide[count - 1])) {
            var extra: DWORD = 0;
            if (ReadConsoleW(input, wide[count..].ptr, 1, &extra, null) != 0) count += extra;
        }
        pending_len = utf16ToUtf8(wide[0..count], &pending);
    }
    const n = @min(out.len, pending_len);
    @memcpy(out[0..n], pending[0..n]);
    @memmove(pending[0 .. pending_len - n], pending[n..pending_len]);
    pending_len -= n;
    return n;
}

fn utf16ToUtf8(wide: []const u16, out: []u8) usize {
    var written: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(wide);
    while (true) {
        const cp = (it.nextCodepoint() catch std.unicode.replacement_character) orelse break;
        const len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        if (written + len > out.len) break;
        _ = std.unicode.utf8Encode(cp, out[written..][0..len]) catch unreachable;
        written += len;
    }
    return written;
}

test "translateKey writes xterm sequences with modifiers" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", buf[0..translateKey(0x26, 0, &buf)]);
    try std.testing.expectEqualStrings("\x1b[1;5C", buf[0..translateKey(0x27, LEFT_CTRL_PRESSED, &buf)]);
    try std.testing.expectEqualStrings("\x1b[3~", buf[0..translateKey(0x2E, 0, &buf)]);
    try std.testing.expectEqualStrings("\x1b[5;2~", buf[0..translateKey(0x21, SHIFT_PRESSED, &buf)]);
    try std.testing.expectEqual(@as(usize, 0), translateKey(0x41, 0, &buf));
}

test "utf16ToUtf8 encodes surrogate pairs and stops at the buffer end" {
    const wide = [_]u16{ 'a', 0xD83D, 0xDE00, 'b' };
    var out: [8]u8 = undefined;
    const n = utf16ToUtf8(&wide, &out);
    try std.testing.expectEqualStrings("a\u{1F600}b", out[0..n]);
    var small: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), utf16ToUtf8(&wide, &small));
}

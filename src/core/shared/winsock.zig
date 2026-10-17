//! The Winsock calls fx needs where the standard library's POSIX socket
//! helpers have no Windows form: waiting for a socket to become readable and
//! setting send and receive timeouts. Only called on Windows.

const std = @import("std");

const Socket = std.posix.socket_t;

const PollFd = extern struct {
    fd: Socket,
    events: i16,
    revents: i16,
};

const POLLRDNORM: i16 = 0x0100;
const POLLRDBAND: i16 = 0x0200;
const POLLIN: i16 = POLLRDNORM | POLLRDBAND;
const POLLERR: i16 = 0x0001;
const POLLHUP: i16 = 0x0002;

const SOL_SOCKET: i32 = 0xffff;
const SO_SNDTIMEO: i32 = 0x1005;
const SO_RCVTIMEO: i32 = 0x1006;

extern "ws2_32" fn WSAPoll(fds: [*]PollFd, count: u32, timeout_ms: i32) callconv(.winapi) i32;
extern "ws2_32" fn setsockopt(socket: Socket, level: i32, name: i32, value: [*]const u8, len: i32) callconv(.winapi) i32;

pub const Readiness = enum { timeout, readable, failed };

/// Waits up to `timeout_ms` (negative waits forever) for `socket` to have
/// data or a pending connection.
pub fn waitReadable(socket: Socket, timeout_ms: i32) !Readiness {
    var fds = [_]PollFd{.{ .fd = socket, .events = POLLIN, .revents = 0 }};
    const rc = WSAPoll(&fds, fds.len, timeout_ms);
    if (rc < 0) return error.SocketPollFailed;
    if (rc == 0) return .timeout;
    if (fds[0].revents & POLLIN != 0) return .readable;
    if (fds[0].revents & (POLLERR | POLLHUP) != 0) return .failed;
    return .timeout;
}

pub const Direction = enum { receive, send };

/// Winsock takes socket timeouts as milliseconds in a `DWORD`, not a
/// `timeval`.
pub fn setTimeout(socket: Socket, direction: Direction, millis: u32) !void {
    const bytes = std.mem.asBytes(&millis);
    const name = switch (direction) {
        .receive => SO_RCVTIMEO,
        .send => SO_SNDTIMEO,
    };
    if (setsockopt(socket, SOL_SOCKET, name, bytes, bytes.len) != 0) return error.SocketOptionFailed;
}

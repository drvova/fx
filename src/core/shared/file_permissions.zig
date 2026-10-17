//! Windows file permissions with the POSIX mode helpers fx uses everywhere.
//!
//! The standard library's Windows `std.Io.File.Permissions` holds file
//! attributes and has no `fromMode` or `toMode`. fx creates its private state
//! with explicit modes such as `0o600` and `0o700`, so the root module installs
//! this type through `std_options_FilePermissions` on Windows and keeps the
//! standard type everywhere else.
//!
//! Windows has no mode bits. `fromMode` keeps the one bit Windows can store,
//! write access, as the read-only attribute. Owner-only access comes from the
//! user profile's inherited ACL instead of the mode, so callers that verify
//! private modes use `isExactly` and `grantsGroupOrOther` rather than
//! `toMode`. Windows stat results also never carry attributes, so they always
//! read as `default_file`.

const std = @import("std");
const builtin = @import("builtin");

/// The type the root module installs, or null to keep the standard one.
pub const Override: ?type = if (builtin.target.os.tag == .windows) WindowsPermissions else null;

/// Whether `toMode` reports real POSIX mode bits.
pub const has_mode_bits = builtin.target.os.tag != .windows;

/// Whether `permissions` grant exactly `mode` (such as `0o600`). Always true
/// on Windows, where the inherited profile ACL, not the mode, keeps fx's state
/// private.
pub fn isExactly(permissions: std.Io.File.Permissions, mode: u32) bool {
    if (comptime !has_mode_bits) return true;
    return permissions.toMode() & 0o777 == mode;
}

/// Whether group or other classes have any access. Always false on Windows,
/// for the reason `isExactly` gives.
pub fn grantsGroupOrOther(permissions: std.Io.File.Permissions) bool {
    if (comptime !has_mode_bits) return false;
    return permissions.toMode() & 0o077 != 0;
}

const WindowsPermissions = enum(u32) {
    default_file = 0,
    _,

    pub const default_dir: @This() = .default_file;
    pub const executable_file: @This() = .default_file;
    pub const has_executable_bit = false;

    const windows = std.os.windows;

    pub fn toAttributes(self: @This()) windows.FILE.ATTRIBUTE {
        return @bitCast(@backingInt(self));
    }

    pub fn readOnly(self: @This()) bool {
        return self.toAttributes().READONLY;
    }

    pub fn setReadOnly(self: @This(), read_only: bool) @This() {
        var attributes = self.toAttributes();
        attributes.READONLY = read_only;
        return @fromBackingInt(@bitCast(attributes));
    }

    /// Keeps only whether any class may write.
    pub fn fromMode(mode: u32) @This() {
        return WindowsPermissions.default_file.setReadOnly(mode & 0o222 == 0);
    }

    /// A synthesized mode: `0o444` when read-only, otherwise `0o666`.
    pub fn toMode(self: @This()) u32 {
        return if (self.readOnly()) 0o444 else 0o666;
    }
};

test "windows permissions keep only the write bit" {
    const P = WindowsPermissions;
    try std.testing.expect(P.fromMode(0o444).readOnly());
    try std.testing.expect(!P.fromMode(0o600).readOnly());
    try std.testing.expectEqual(@as(u32, 0o444), P.fromMode(0o500).toMode());
    try std.testing.expectEqual(@as(u32, 0o666), P.fromMode(0o700).toMode());
}

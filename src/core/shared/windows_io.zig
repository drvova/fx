//! Fills the Windows gaps in Zig 0.17's threaded `std.Io`, which panics in
//! `Dir.setPermissions` and `Dir.setFilePermissions`. fx sets owner-only
//! modes on its state directories and files everywhere, so `io.zig` installs
//! this wrapper on Windows the way it installs `darwin_process_spawn.zig` on
//! macOS.
//!
//! A directory's only permission on Windows is its ACL, so setting a mode on
//! one does nothing (see `file_permissions.zig`). A file keeps its read-only
//! attribute, which `File.setPermissions` already sets on Windows.

const std = @import("std");

var wrapped_vtable: std.Io.VTable = undefined;
var wrapped_original_vtable: ?*const std.Io.VTable = null;

pub fn wrap(original: std.Io) std.Io {
    if (wrapped_original_vtable) |original_vtable| {
        std.debug.assert(original_vtable == original.vtable);
    } else {
        wrapped_vtable = original.vtable.*;
        wrapped_vtable.dirSetPermissions = dirSetPermissions;
        wrapped_vtable.dirSetFilePermissions = dirSetFilePermissions;
        wrapped_original_vtable = original.vtable;
    }
    return .{
        .userdata = original.userdata,
        .vtable = &wrapped_vtable,
    };
}

fn dirSetPermissions(_: ?*anyopaque, _: std.Io.Dir, _: std.Io.Dir.Permissions) std.Io.Dir.SetPermissionsError!void {}

fn dirSetFilePermissions(
    userdata: ?*anyopaque,
    dir: std.Io.Dir,
    sub_path: []const u8,
    permissions: std.Io.File.Permissions,
    _: std.Io.Dir.SetFilePermissionsOptions,
) std.Io.Dir.SetFilePermissionsError!void {
    const original: std.Io = .{ .userdata = userdata, .vtable = wrapped_original_vtable.? };
    const stat = dir.statFile(original, sub_path, .{}) catch |err| return mapError(err);
    if (stat.kind == .directory) return;
    var file = dir.openFile(original, sub_path, .{ .mode = .read_write }) catch |err| return mapError(err);
    defer file.close(original);
    file.setPermissions(original, permissions) catch |err| return mapError(err);
}

fn mapError(err: anyerror) std.Io.Dir.SetFilePermissionsError {
    return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.Canceled => error.Canceled,
        else => error.Unexpected,
    };
}

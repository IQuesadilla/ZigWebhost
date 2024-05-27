const std = @import("std");

pub const ConnectionsList = std.SinglyLinkedList(ConnectionData);

pub const ThreadStatus = enum { Connected, Available, Selected, Killed };

pub const ServerStatus = struct {
    running: bool,
    webroot: std.fs.Dir,
};

pub const ConnectionData = struct {
    thread: std.Thread,
    connection: std.http.Server.Response,
    status: ThreadStatus,
    synclock: std.Thread.ResetEvent,
    server: *ServerStatus,
};

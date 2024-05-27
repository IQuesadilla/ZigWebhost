const std = @import("std");
const types = @import("types.zig");

const MSG404 = "<html><head></head><body><h1>404</h1></body></html>";

pub fn HandleClient(ThreadData: *types.ConnectionData) void {
    defer ThreadData.status = types.ThreadStatus.Killed;

    while (true) {
        var ContinueWait: bool = true;
        while (ContinueWait) {
            var TimedOut: bool = false;
            ThreadData.synclock.timedWait(std.time.ns_per_min) catch {
                if (ThreadData.status != types.ThreadStatus.Selected) {
                    std.debug.print("Thread timed out\n", .{});
                    return;
                }
                TimedOut = true;
            };
            if (TimedOut == false) ContinueWait = false;
        }
        ThreadData.synclock.reset();

        defer {
            if (ThreadData.server.running) ThreadData.connection.deinit();
            ThreadData.status = types.ThreadStatus.Available;
        }

        if (ThreadData.server.running == false) return;

        std.debug.print("Connection opened to {}\n", .{ThreadData.connection.address});

        ThreadData.connection.wait() catch |err| {
            std.debug.print("Error in connection.wait: {}\n", .{err});
            continue;
        };

        const PathString = ThreadData.connection.request.target;
        var Path = std.Uri.parseWithoutScheme(PathString) catch |err| {
            std.debug.print("Error in Uri.parse: {}\n", .{err});
            continue;
        };

        const FilePathString = if (Path.path.len > 1) Path.path[1..] else "index.html";
        //std.mem.replace(u8, FilePathString, "..", "//", NewFilePathString);
        std.debug.print("The request url: <{s}>\n", .{FilePathString});

        var ItCount: usize = @divFloor(FilePathString.len, 2);
        while (ItCount > 0) {
            const InnerItCount = ItCount * 2;
            if (FilePathString[InnerItCount - 1] == '.' and (FilePathString[InnerItCount - 2] == '.' or (InnerItCount < FilePathString.len and FilePathString[InnerItCount] == '.'))) {
                std.debug.print("Warning: Attempted to access an out of bounds file.\n", .{});
                break;
            }
            ItCount -= 1;
        }
        if (ItCount != 0) continue;

        const FileOpenFlags: std.fs.File.OpenFlags = .{
            .mode = std.fs.File.OpenMode.read_only,
        };

        var FileData: []u8 = undefined;
        var FileHandle = ThreadData.server.webroot.openFile(FilePathString, FileOpenFlags);
        if (FileHandle) |OpenedFile| {
            OpenedFile.seekTo(0) catch unreachable;
            FileData = OpenedFile.readToEndAlloc(ThreadData.connection.allocator, 2048) catch |err| {
                std.debug.print("Error in readFile: {}\n", .{err});
                continue;
            };
        } else |err| {
            std.debug.print("Error in openFile: {}\n", .{err});
            FileData = ThreadData.connection.allocator.alloc(u8, MSG404.len) catch unreachable;
            @memcpy(FileData, MSG404);
        }

        const ClientBody = ThreadData.connection.reader().readAllAlloc(ThreadData.connection.allocator, 1024) catch |err| {
            std.debug.print("Error in connection.reader.readAllAlloc: {}\n", .{err});
            continue;
        };
        ThreadData.connection.allocator.free(ClientBody);

        ThreadData.connection.transfer_encoding = .{
            .content_length = FileData.len,
        };

        ThreadData.connection.do() catch |err| {
            std.debug.print("Error in connection.do: {}\n", .{err});
            continue;
        };

        _ = ThreadData.connection.write(FileData) catch |err| {
            std.debug.print("Error in connection.write: {}\n", .{err});
            continue;
        };
        ThreadData.connection.allocator.free(FileData);

        ThreadData.connection.finish() catch |err| {
            std.debug.print("Error in connection.finish: {}\n", .{err});
            continue;
        };
    }
}

const std = @import("std");

//const SiteCode = "<html></html>";
//var AcceptMutex: std.Thread.Mutex = .{};
//var ContinueMutex: std.Thread.Mutex = .{};
//var ServerRunning: bool = true;
const ConnectionsList = std.SinglyLinkedList(ConnectionData);
const MSG404 = "<html><head></head><body><h1>404</h1></body></html>";
const WebRootPath = "webroot/";
//var SyncLock: std.Thread.ResetEvent = .{};

const ThreadStatus = enum { Connected, Available, Selected, Killed };

const ServerStatus = struct {
    running: bool,
    webroot: std.fs.Dir,
};

const ConnectionData = struct {
    thread: std.Thread,
    connection: std.http.Server.Response,
    status: ThreadStatus,
    synclock: std.Thread.ResetEvent,
    server: *ServerStatus,
};

pub fn HandleClient(ThreadData: *ConnectionData) void {
    defer ThreadData.status = ThreadStatus.Killed;

    while (true) {
        var ContinueWait: bool = true;
        while (ContinueWait) {
            var TimedOut: bool = false;
            ThreadData.synclock.timedWait(std.time.ns_per_min) catch {
                if (ThreadData.status != ThreadStatus.Selected) {
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
            ThreadData.status = ThreadStatus.Available;
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

pub fn main() void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("Starting the server...\n", .{});

    var NetOptions: std.net.StreamServer.Options = .{
        .reuse_port = true,
        .reuse_address = true,
    };

    var NetHeapAlloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(NetHeapAlloc.deinit() == .ok);

    const CurrentPath = std.fs.cwd().realpathAlloc(NetHeapAlloc.allocator(), ".") catch unreachable;
    std.debug.print("CWD: {s}\n", .{CurrentPath});
    NetHeapAlloc.allocator().free(CurrentPath);

    //std.fs.Dir.OpenDirOptions
    var CurrentStatus: ServerStatus = .{
        .running = true,
        .webroot = std.fs.cwd().openDir(WebRootPath, .{}) catch |err| {
            std.debug.print("Error in openDir: {}\n", .{err});
            std.debug.print("Could not find webroot - <{s}>\n", .{WebRootPath});
            return;
        },
    };

    var NetAddr = std.net.Address.resolveIp("0.0.0.0", 3000) catch |err| {
        switch (err) {
            //error.PermissionDenied => { // Just here as an example of handling an individual error
            //    std.debug.print("ERROR: {s}\n", .{"PermissionDenied"});
            //    return;
            //},
            else => {
                std.debug.print("ERROR: {}\n", .{err});
                return;
            },
        }
        return;
    };

    var NetServer = std.http.Server.init(NetHeapAlloc.allocator(), NetOptions);
    defer NetServer.deinit();

    NetServer.listen(NetAddr) catch |err| {
        switch (err) {
            else => {
                std.debug.print("ERROR: {}\n", .{err});
                return;
            },
        }
    };
    //var AcceptHeapAlloc = std.heap.GeneralPurposeAllocator(.{}){};
    //defer std.debug.assert(AcceptHeapAlloc.deinit() == .ok);

    const AcceptOptions: std.http.Server.AcceptOptions = .{
        .allocator = NetHeapAlloc.allocator(),
    };

    var OpenConnections: ConnectionsList = .{};

    var ConnectionsAlloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(ConnectionsAlloc.deinit() == .ok);

    //if (SyncLock.isSet())
    //    SyncLock.reset();
    //var ServerLoop: bool = true;
    while (CurrentStatus.running) {
        //AcceptMutex.lock();

        var AvailableNode: ?*ConnectionsList.Node = null;
        { // For - removing "var it" from other scopes
            var it = OpenConnections.first;
            while (it) |node| {
                it = node.next;
                if (node.data.status == ThreadStatus.Killed) {
                    OpenConnections.remove(node);
                    node.data.thread.join();
                    ConnectionsAlloc.allocator().destroy(node);
                } else if (node.data.status == ThreadStatus.Available) {
                    // TODO: Status can change from Available to Killed between these two instructions, causing a race
                    node.data.status = ThreadStatus.Selected;
                    AvailableNode = node;
                }
            }
        }

        if (AvailableNode == null) {
            var NewConnNode = ConnectionsAlloc.allocator().create(ConnectionsList.Node) catch |err| {
                std.debug.print("ERROR: {}\n", .{err});
                return;
            };

            NewConnNode.data = ConnectionData{
                .synclock = .{},
                .status = ThreadStatus.Selected,
                .server = &CurrentStatus,
                .thread = undefined,
                .connection = undefined,
            };
            NewConnNode.data.synclock.set();
            NewConnNode.data.synclock.reset();

            OpenConnections.prepend(NewConnNode);

            const ThreadConfig: std.Thread.SpawnConfig = .{};
            NewConnNode.data.thread = std.Thread.spawn(ThreadConfig, HandleClient, .{&NewConnNode.data}) catch |err| {
                std.debug.print("ERROR: {}\n", .{err});
                return;
            };

            AvailableNode = NewConnNode;
        }

        var OperatingNode = AvailableNode orelse return;

        var LinuxSocket = NetServer.socket.sockfd orelse unreachable;

        var AcceptLoop: bool = true;
        while (AcceptLoop) {
            var fds = [_]std.os.pollfd{
                std.os.pollfd{ .fd = LinuxSocket, .events = std.os.POLL.IN, .revents = 0 },
                std.os.pollfd{ .fd = std.io.getStdIn().handle, .events = std.os.POLL.IN, .revents = 0 },
            };
            const nfds = std.os.poll(&fds, 1000) catch |err| {
                std.debug.print("Error - poll: {}\n", .{err});
                return;
            };
            if (nfds == 0) {
                var it = OpenConnections.first;
                while (it) |node| {
                    it = node.next;
                    if (node.data.status == ThreadStatus.Killed) {
                        OpenConnections.remove(node);
                        node.data.thread.join();
                        ConnectionsAlloc.allocator().destroy(node);
                    }
                }
                //std.debug.print("Timeout reached, looping\n", .{});
            } else {
                if ((fds[0].revents * std.os.POLL.IN) != 0) {
                    OperatingNode.data.connection = NetServer.accept(AcceptOptions) catch |err| {
                        switch (err) {
                            else => {
                                std.debug.print("ERROR: {}\n", .{err});
                                return;
                            },
                        }
                    };

                    std.debug.print("Unlocking thread\n", .{});
                    OperatingNode.data.status = ThreadStatus.Connected;
                    OperatingNode.data.synclock.set();
                    //SyncLock.reset();

                    AcceptLoop = false;
                }

                if ((fds[1].revents * std.os.POLL.IN) != 0) {
                    var Input = std.io.getStdIn().reader().readUntilDelimiterAlloc(NetHeapAlloc.allocator(), '\n', 1024) catch return;
                    //std.debug.print("Recieved from stdin <{s}>\n", .{Input});
                    if (std.mem.eql(u8, Input, "quit")) {
                        std.debug.print("Killing server; Performing cleanup\n", .{});
                        AcceptLoop = false;
                        CurrentStatus.running = false;
                    } else if (std.mem.eql(u8, Input, "tcount")) {
                        std.debug.print("Current number of child threads: {}\n", .{OpenConnections.len()});
                    }
                    NetHeapAlloc.allocator().free(Input);
                }
            }
        }
    }

    while (OpenConnections.len() > 0) {
        std.debug.print("Threads still open: {}\n", .{OpenConnections.len()});
        var RemovingNode: *ConnectionsList.Node = OpenConnections.popFirst() orelse break;
        RemovingNode.data.synclock.set();
        RemovingNode.data.thread.join();
        ConnectionsAlloc.allocator().destroy(RemovingNode);
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

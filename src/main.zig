const std = @import("std");
const types = @import("types.zig");
const clients = @import("thread.zig");
const term = @import("interface.zig");

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

    const WebRootPath = "webroot/";
    var CurrentStatus: types.ServerStatus = .{
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

    var OpenConnections: types.ConnectionsList = .{};

    var ConnectionsAlloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(ConnectionsAlloc.deinit() == .ok);

    //if (SyncLock.isSet())
    //    SyncLock.reset();
    //var ServerLoop: bool = true;
    while (CurrentStatus.running) {
        //AcceptMutex.lock();

        var AvailableNode: ?*types.ConnectionsList.Node = null;
        { // For - removing "var it" from other scopes
            var it = OpenConnections.first;
            while (it) |node| {
                it = node.next;
                if (node.data.status == types.ThreadStatus.Killed) {
                    OpenConnections.remove(node);
                    node.data.thread.join();
                    ConnectionsAlloc.allocator().destroy(node);
                } else if (node.data.status == types.ThreadStatus.Available) {
                    // TODO: Status can change from Available to Killed between these two instructions, causing a race
                    node.data.status = types.ThreadStatus.Selected;
                    AvailableNode = node;
                }
            }
        }

        if (AvailableNode == null) {
            var NewConnNode = ConnectionsAlloc.allocator().create(types.ConnectionsList.Node) catch |err| {
                std.debug.print("ERROR: {}\n", .{err});
                return;
            };

            NewConnNode.data = types.ConnectionData{
                .synclock = .{},
                .status = types.ThreadStatus.Selected,
                .server = &CurrentStatus,
                .thread = undefined,
                .connection = undefined,
            };
            NewConnNode.data.synclock.set();
            NewConnNode.data.synclock.reset();

            OpenConnections.prepend(NewConnNode);

            const ThreadConfig: std.Thread.SpawnConfig = .{};
            NewConnNode.data.thread = std.Thread.spawn(ThreadConfig, clients.HandleClient, .{&NewConnNode.data}) catch |err| {
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
                    if (node.data.status == types.ThreadStatus.Killed) {
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
                    OperatingNode.data.status = types.ThreadStatus.Connected;
                    OperatingNode.data.synclock.set();
                    //SyncLock.reset();

                    AcceptLoop = false;
                }

                if ((fds[1].revents * std.os.POLL.IN) != 0) {
                    term.TermInterface();
                }
            }
        }
    }

    while (OpenConnections.len() > 0) {
        std.debug.print("Threads still open: {}\n", .{OpenConnections.len()});
        var RemovingNode: *types.ConnectionsList.Node = OpenConnections.popFirst() orelse break;
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

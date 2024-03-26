const std = @import("std");

const SiteCode = "<html></html>";
var AcceptMutex: std.Thread.Mutex = .{};
var ContinueMutex: std.Thread.Mutex = .{};

const ThreadStatus = enum { Connected, Available, Killed };

const ConnectionData = struct {
    thread: std.Thread,
    connection: std.http.Server.Response,
    status: ThreadStatus,
};

// An open thread should signal in some way to the running thread that it is
// available to handle a new connection; this should help eliminate the constant
// creation and deletion of threads

pub fn HandleClient(InNetResponse: *ConnectionData) void {
    ContinueMutex.lock();
    AcceptMutex.lock();
    ContinueMutex.unlock();
    AcceptMutex.unlock();

    var NetResponse = &InNetResponse.connection;

    std.debug.print("Connection opened to {}\n", .{NetResponse.address});

    NetResponse.wait() catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
    };

    //var doReadLoop: bool = true;
    //while (doReadLoop) {
    //    NetResponse.read() catch |err| {
    //        switch (err) {
    //            else => {
    //                std.debug.print("ERROR: {}\n", .{err});
    //                return;
    //            },
    //        }
    //    };
    //}

    //var AcceptHeapAlloc = std.heap.GeneralPurposeAllocator(.{}){};
    //defer std.debug.assert(AcceptHeapAlloc.deinit() == .ok);

    const ClientBody = NetResponse.reader().readAllAlloc(NetResponse.allocator, 1024) catch unreachable;
    std.debug.print("The response body: <{s}>\n", .{ClientBody});

    NetResponse.transfer_encoding = .{
        .content_length = SiteCode.len,
    };

    NetResponse.do() catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
    };

    _ = NetResponse.write(SiteCode) catch |err| {
        switch (err) {
            else => {
                std.debug.print("ERROR: {}\n", .{err});
                return;
            },
        }
    };

    NetResponse.finish() catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
    };

    NetResponse.deinit();
}

pub fn ThreadSpawner(NetServer: *std.http.Server) void {
    var AcceptHeapAlloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(AcceptHeapAlloc.deinit() == .ok);

    const AcceptOptions: std.http.Server.AcceptOptions = .{
        .allocator = AcceptHeapAlloc.allocator(),
    };

    const ConnectionsList = std.SinglyLinkedList(ConnectionData);
    var OpenConnections: ConnectionsList = .{};

    var ConnectionsAlloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(ConnectionsAlloc.deinit() == .ok);

    var TempConnectionCount: usize = 5;

    while (TempConnectionCount > 0) {
        AcceptMutex.lock();

        var NewConnNode = ConnectionsAlloc.allocator().create(ConnectionsList.Node) catch |err| {
            std.debug.print("ERROR: {}\n", .{err});
            return;
        };

        OpenConnections.prepend(NewConnNode);

        const ThreadConfig: std.Thread.SpawnConfig = .{};

        NewConnNode.data.thread = std.Thread.spawn(ThreadConfig, HandleClient, .{&NewConnNode.data}) catch |err| {
            std.debug.print("ERROR: {}\n", .{err});
            return;
        };

        NewConnNode.data.connection = NetServer.accept(AcceptOptions) catch |err| {
            switch (err) {
                else => {
                    std.debug.print("ERROR: {}\n", .{err});
                    return;
                },
            }
        };

        //NetResponseOpt = &NewConnNode.data.connection;
        AcceptMutex.unlock();

        ContinueMutex.lock();
        ContinueMutex.unlock();

        TempConnectionCount -= 1;
    }

    while (OpenConnections.len() > 0) {
        std.debug.print("Connections still open: {}\n", .{OpenConnections.len()});
        var RemovingNode: *ConnectionsList.Node = OpenConnections.popFirst() orelse break;
        RemovingNode.data.thread.join();
        ConnectionsAlloc.allocator().destroy(RemovingNode);
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

    const ThreadConfig: std.Thread.SpawnConfig = .{
        .allocator = NetHeapAlloc.allocator(),
    };
    var SpawnerThread = std.Thread.spawn(ThreadConfig, ThreadSpawner, .{&NetServer}) catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
        return;
    };
    SpawnerThread.join();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

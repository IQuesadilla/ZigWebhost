const std = @import("std");

fn TermInterface() void {
    var Input = std.io.getStdIn().reader().readUntilDelimiterAlloc(NetHeapAlloc.allocator(), '\n', 1024) catch return;
                    //std.debug.print("Recieved from stdin <{s}>\n", .{Input});
                    if (std.mem.eql(u8, Input, "quit")) {
                        std.debug.print("Killing server; Performing cleanup\n", .{});
                        AcceptLoop = false;
                        CurrentStatus.running = false;
                    } else if (std.mem.eql(u8, Input, "threads")) {
                        var AvailCount: usize = 0;
                        var ConnCount: usize = 0;
                        var SelCount: usize = 0;
                        var KillCount: usize = 0;

                        var Node = OpenConnections.first;
                        while (Node) |Conn| {
                            switch (Conn.data.status) {
                                types.ThreadStatus.Available => {
                                    AvailCount += 1;
                                },
                                types.ThreadStatus.Connected => {
                                    ConnCount += 1;
                                },
                                types.ThreadStatus.Selected => {
                                    SelCount += 1;
                                },
                                types.ThreadStatus.Killed => {
                                    KillCount += 1;
                                },
                            }
                            Node = Conn.next;
                        }
                        std.debug.print("Available: {d}, Connected: {d}, Selected: {d}, Killed: {d}\n", .{ AvailCount, ConnCount, SelCount, KillCount });
                    }
                    NetHeapAlloc.allocator().free(Input);

}

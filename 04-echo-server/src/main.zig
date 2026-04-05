const std = @import("std");
const posix = std.posix;
const net = std.net;

// Maximum number of simultaneous client connections we support.
// poll() watches one fd per client, so this caps our poll_fds array size.
const max_clients = 128;

pub fn main() !void {
    // Bind to all interfaces (0.0.0.0) on port 1378.
    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, 1378);

    // Create a TCP (STREAM) socket.
    // NONBLOCK makes accept() return immediately with `error.WouldBlock`
    // instead of sleeping when no pending connection exists — this is
    // essential for multiplexed I/O so we never block on a single fd.
    const server = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    defer posix.close(server);

    // SO_REUSEADDR lets us restart the server immediately after stopping it
    // without waiting for the kernel's TIME_WAIT state to expire on the port.
    try posix.setsockopt(server, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    // bind() associates our socket with the address/port so the OS knows
    // to deliver incoming packets on port 1378 to this socket.
    try posix.bind(server, &address.any, address.getOsSockLen());

    // listen() moves the socket into the LISTEN state and tells the kernel
    // to start accepting TCP handshakes.  The second argument (128) is the
    // *backlog* — the maximum number of completed TCP connections that can
    // queue up waiting for our accept() call.  If the queue is full, new
    // clients get a connection-refused error.
    try posix.listen(server, 128);

    std.log.info("listening on 0.0.0.0:1378", .{});

    // ---------------------------------------------------------------
    // poll_fds layout:
    //   [0]              -> the listening server socket
    //   [1..max_clients] -> connected client sockets
    //
    // We pass a *slice* of this array (only the active portion) to poll().
    // client_count tracks how many client slots are in use.
    // ---------------------------------------------------------------
    var poll_fds: [1 + max_clients]posix.pollfd = undefined;
    var client_count: usize = 0;

    // Register the listening socket.  We only care about POLL.IN (readable),
    // which fires when a new client connection is ready to be accepted.
    const server_pollfd = posix.pollfd{
        .fd = server,
        .events = posix.POLL.IN,
        .revents = 0,
    };
    poll_fds[0] = server_pollfd;

    // Mark all client slots as unused (fd = -1 is ignored by poll).
    const unused_pollfd = posix.pollfd{
        .fd = -1,
        .events = 0,
        .revents = 0,
    };
    for (poll_fds[1..]) |*pfd| {
        pfd.* = unused_pollfd;
    }

    // ---------- Main event loop ----------
    // A single thread handles all connections by asking the kernel
    // "which of these fds have something to do?" via poll().
    // This is *multiplexed I/O* — instead of one thread/process per
    // connection, one poll() call watches every fd at once.
    while (true) {
        // Only pass the active portion of the array to poll().
        const active = poll_fds[0 .. 1 + client_count];

        // poll() blocks until at least one fd has an event.
        // The timeout of -1 means "wait forever".
        // When it returns, each fd's `revents` field is filled in
        // with what actually happened (data ready, error, hangup, …).
        _ = try posix.poll(active, -1);

        // If the listening socket is readable, a new client is knocking.
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            accept(&poll_fds, &client_count, server);
        }

        // Walk through every connected client and handle events.
        var i: usize = 1;
        while (i <= client_count) {
            const revents = poll_fds[i].revents;
            if (revents == 0) {
                // No event on this fd — skip.
                i += 1;
                continue;
            }

            if (revents & posix.POLL.IN != 0) {
                // Data available to read — echo it back.
                // echo() returns false when the client disconnected or errored.
                if (!echoBack(poll_fds[i].fd)) {
                    removeClient(&poll_fds, &client_count, i);
                    // Don't increment i: the slot now holds a different
                    // client (swapped from the end) that still needs checking.
                    continue;
                }
            } else if (revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
                // ERR  — socket-level error
                // HUP  — peer hung up (closed their end)
                // NVAL — fd is not valid (shouldn't happen, but handle gracefully)
                removeClient(&poll_fds, &client_count, i);
                continue;
            }

            i += 1;
        }
    }
}

/// Accept a new incoming connection and register it in the poll set.
fn accept(poll_fds: *[1 + max_clients]posix.pollfd, client_count: *usize, server: posix.fd_t) void {
    // accept() dequeues one completed connection from the backlog.
    // We pass NONBLOCK so reads/writes on this client socket also
    // never block — keeping our event loop responsive.
    const conn = posix.accept(server, null, null, posix.SOCK.NONBLOCK) catch |err| {
        std.log.err("accept failed: {}", .{err});
        return;
    };

    if (client_count.* >= max_clients) {
        std.log.warn("max clients reached, rejecting connection", .{});
        posix.close(conn);
        return;
    }

    // Place the new client in the next free slot.
    client_count.* += 1;
    const client_pollfd = posix.pollfd{
        .fd = conn,
        .events = posix.POLL.IN, // we only need to know when data arrives
        .revents = 0,
    };
    poll_fds[client_count.*] = client_pollfd;

    std.log.info("client connected (fd={}), total={}", .{ conn, client_count.* });
}

/// Read whatever the client sent and write it straight back (echo).
/// Returns false if the client should be removed (disconnect or error).
fn echoBack(fd: posix.fd_t) bool {
    var buf: [4096]u8 = undefined;

    // read() returns 0 when the peer has closed the connection (FIN).
    const n = posix.read(fd, &buf) catch {
        return false;
    };
    if (n == 0) return false;

    // Write the exact bytes back.  Because the socket is non-blocking
    // we loop until everything is sent (short writes are possible).
    var sent: usize = 0;
    while (sent < n) {
        sent += posix.write(fd, buf[sent..n]) catch {
            return false;
        };
    }

    return true;
}

/// Remove a client from the poll set by swapping it with the last active slot.
/// This avoids shifting the entire array — O(1) removal.
fn removeClient(poll_fds: *[1 + max_clients]posix.pollfd, client_count: *usize, idx: usize) void {
    std.log.info("client disconnected (fd={}), total={}", .{ poll_fds[idx].fd, client_count.* - 1 });
    posix.close(poll_fds[idx].fd);

    // Swap-remove: overwrite the removed slot with the last active entry,
    // then blank out the now-unused last slot.
    poll_fds[idx] = poll_fds[client_count.*];
    const unused_pollfd = posix.pollfd{
        .fd = -1,
        .events = 0,
        .revents = 0,
    };
    poll_fds[client_count.*] = unused_pollfd;
    client_count.* -= 1;
}

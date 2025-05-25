create_client_request_reader :: (client_socket_fd: s32) -> *Event_Loop.Event_Data {
    data := New(Client_Request_Reader_EData);
    data.* = .{ client_socket_fd };
    request_reader := New(Event_Loop.Event_Data);
    request_reader.* = .{ data, client_request_read };
    return request_reader;
}

#scope_file

Client_Request_Reader_EData :: struct {
    socket_fd: s32; // client socket where data will be read from and written to
}

client_request_read :: (ev_loop: *Event_Loop.Event_Loop, event_data: *Event_Loop.Event_Data)  {
    // @note
    // clean up event data - as connection will get closed after this request is complete.
    // maybe we can't do this later, when we introduce one more layer where we proxy request to backend
    defer Event_Loop.evl_deinit_event_data(event_data);

    ctx := cast(*Client_Request_Reader_EData, event_data.ctx);
    client_socket_fd := ctx.*.socket_fd;
    log("Client request reader called: fd = %, event_loop: %", client_socket_fd, ev_loop.*);

    defer {
        log("Cleaning up resources for fd = %", client_socket_fd);
        Event_Loop.evl_unregister(ev_loop, client_socket_fd, .READ);
        array_unordered_remove_by_value(*ev_loop.registered_fds, client_socket_fd);
        POSIX.close(client_socket_fd);
    }

    buffer : [BUFFER_SIZE]u8;
    read_count := POSIX.read(client_socket_fd, buffer.data, BUFFER_SIZE -1);
    if read_count == -1 {
        log_error("read failed: %", System.get_error_string(POSIX.errno()));
        return;
    }
    if read_count == 0 {
        log("Client disconnected: %", System.get_error_string(POSIX.errno()));
        return;
    }
    received := to_string(buffer.data, read_count);
    log("Received: %", received);

    reply := tprint("Hello: %", received);
    if Socket.send(client_socket_fd, reply.data, xx reply.count, 0) == -1 {
        log_error("send failed: %", System.get_error_string(POSIX.errno()));
        return;
    }
}

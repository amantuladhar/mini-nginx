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
    mark := get_temporary_storage_mark();
    defer {
        set_temporary_storage_mark(mark);
        // @note
        // clean up event data - as connection will get closed after this request is complete.
        // maybe we can't do this later, when we introduce one more layer where we proxy request to backend
        Event_Loop.evl_deinit_event_data(event_data);
    }

    ctx := cast(*Client_Request_Reader_EData) event_data.ctx;
    client_socket_fd := ctx.*.socket_fd;
    log("Client request reader called: fd = %, event_loop: %", client_socket_fd, ev_loop.*);

    defer {
        log("Cleaning up resources for fd = %", client_socket_fd);
        Event_Loop.evl_unregister(ev_loop, client_socket_fd, .READ);
        array_unordered_remove_by_value(*ev_loop.registered_fds, client_socket_fd);
        POSIX.close(client_socket_fd);
    }
    success, request := Http.http_read_request(client_socket_fd);
    defer Http.http_deinit(*request);

    if !success {
        log_error("Failed to read HTTP request");
        return;
    }

    http_res := Http.http_init_res();
    Http.http_resp_deinit(*http_res);
    Http.http_resp_set_status_code(*http_res, .OK);
    Http.http_res_add_header(*http_res, "Content-Type", "text/plain");
    Http.http_res_set_body(*http_res, "Hello, HTTP!!!");
    bytes := Http.http_res_to_bytes(*http_res);
    defer free(bytes.data,, http_res.allocator);

    if Socket.send(client_socket_fd, bytes.data, xx bytes.count, 0) == -1 {
        log_error("send failed: %", System.get_error_string(POSIX.errno()));
        return;
    }
}

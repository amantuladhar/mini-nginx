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
    defer Event_Loop.evl_deinit_event_data(event_data);

    ctx := cast(*Client_Request_Reader_EData) event_data.ctx;
    client_socket_fd := ctx.*.socket_fd;
    log("Client request reader called: fd = %, event_loop: %", client_socket_fd, ev_loop.*);

    defer {
        log("Cleaning up resources for fd = %", client_socket_fd);
        Event_Loop.evl_unregister(ev_loop, client_socket_fd, .READ);
        array_unordered_remove_by_value(*ev_loop.registered_fds, client_socket_fd);
        POSIX.close(client_socket_fd);
    }
    success, request := Http.http_parse_request(client_socket_fd);
    // defer Http.http_deinit(*request);

    if !success {
        log_error("Failed to read HTTP request");
        return;
    }

    do_proxy :: true;
    if do_proxy {
        proxy_addr := "127.0.0.1";
        proxy_port : u16 = 9999;
        proxy_fd := Socket.socket(Socket.AF_INET, .STREAM, 0);
        if proxy_fd == -1 {
            log_error("socket creation failed: %", System.get_error_string(POSIX.errno()));
            exit(1);
        }
        defer POSIX.close(proxy_fd);
        // set_nonblocking(proxy_fd);

        address := Socket.sockaddr_in.{
            sin_family = Socket.AF_INET,
            sin_addr = Socket.in_addr.{ s_addr = Socket.inet_addr(proxy_addr.data) },
            sin_port = Socket.htons(proxy_port),
        };
        proxy_connect_result :=Socket.connect(proxy_fd, xx *address, size_of(Socket.sockaddr_in));
        if  proxy_connect_result == -1 {
            log_error("connect failed: %", System.get_error_string(POSIX.errno()));
            return;
        }
        log("Sending to proxy: % -- %", request.socket_reader.buffer.count, string.{request.socket_reader.buffer.count, request.socket_reader.buffer.data});

        proxy_send_count := Socket.send(proxy_fd, request.socket_reader.buffer.data, xx request.socket_reader.buffer.count, 0);
        log("Number of bytes send to proxy - %", proxy_send_count);
        if proxy_send_count == -1 {
            log_error("proxy send failed: %", System.get_error_string(POSIX.errno()));
            return;
        }

        proxy_resp_buffer: [4096]u8;
        read_count := POSIX.read(proxy_fd, proxy_resp_buffer.data, 4096);
        if read_count == -1 {
            log_error("read failed: %", System.get_error_string(POSIX.errno()));
            return;
        }
        log("Received from proxy: %", string.{read_count, proxy_resp_buffer.data});

        client_send_count := Socket.send(client_socket_fd, proxy_resp_buffer.data, xx read_count, 0);
        if client_send_count == -1 {
            log_error("send failed: %", System.get_error_string(POSIX.errno()));
            return;
        }
    } else {
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
}

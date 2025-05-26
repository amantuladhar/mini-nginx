create_client_connection_acceptor :: (master_socket_fd: s32) -> *Event_Loop.Event_Data {
    data := New(Client_Conn_Acceptor_EData);
    data.* = .{ master_socket_fd };
    conn_accept_edata := New(Event_Loop.Event_Data);
    conn_accept_edata.* = .{ data, client_conn_acceptor };
    return conn_accept_edata;
}

#scope_file

Client_Conn_Acceptor_EData :: struct {
    master_socket_fd: s32; // server socket where connection will be accepted
}

client_conn_acceptor :: (ev_loop: *Event_Loop.Event_Loop, event_data: *Event_Loop.Event_Data) {
    ctx := cast(*Client_Conn_Acceptor_EData) event_data.ctx;
    master_socket_fd := ctx.*.master_socket_fd;

    log("Connection acceptor called. fd = %, event_loop: %", master_socket_fd, ev_loop.*);

    client_addr: Socket.sockaddr_in;
    addr_len: Socket.socklen_t = size_of(Socket.sockaddr_in);

    client_socket_fd := Socket.accept(master_socket_fd, cast(*Socket.sockaddr, *client_addr), *addr_len);
    if client_socket_fd == -1 {
        log_error("accept failed: %", System.get_error_string(POSIX.errno()));
        return;
    }
    array_add(*ev_loop.registered_fds, client_socket_fd);

    // This gets freed on procedure that gets called when read event is triggered
    // req_reader := create_client_request_reader(client_socket_fd);
    // Event_Loop.evl_register(ev_loop, client_socket_fd, .READ, req_reader);

    // client_address := to_string(Socket.inet_ntoa(client_addr.sin_addr));
    // client_port := Socket.ntohs(client_addr.sin_port);
    // log("Accepted connection from %:%", client_address, client_port);

    worker := create_proxy_worker(master_socket_fd, client_socket_fd);
    worker_edata := New(Event_Loop.Event_Data);
    worker_edata.* = .{*worker, proxy_worker_process };

    Event_Loop.evl_register(ev_loop, client_socket_fd, .READ, worker_edata);
}

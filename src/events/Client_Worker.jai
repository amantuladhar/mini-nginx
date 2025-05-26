handle_state_transition :: (using worker: *Proxy_Worker_Ctx) {
    if master_socket_fd == -1 {
        log_error("Master socket fd is not set, cannot transition to WAITING_FOR_CONN");
        state = .ERROR;
        return;
    }
    if state == .WAITING_FOR_CLIENT_REQ {
        if proxy_socket_fd == -1 {
            log_error("Proxy server fd is not set, cannot transition to WAITING_FOR_PROXY_CONN");
            state = .ERROR;
            return;
        }
        state = .WAITING_FOR_PROXY_WRITE;
        return;
    }
    if state == .WAITING_FOR_PROXY_WRITE {
        state = .WAITING_FOR_PROXY_READ;
        return;
    }
    if state == .WAITING_FOR_PROXY_READ {
        state = .COMPLETE;
        return;
    }
    if state == .ERROR {
        return;
    }
    log_error("Invalid state transition from %, cannot transition to ERROR", state);
    state = .ERROR;
}

create_proxy_worker :: (master_socket_fd: s32, client_socket_fd: s32) -> Proxy_Worker_Ctx {
    worker := New(Proxy_Worker_Ctx);
    worker.* = .{
        master_socket_fd = master_socket_fd,
        client_socket_fd = client_socket_fd,
        state            = .WAITING_FOR_CLIENT_REQ,
        allocator        = context.allocator,
    };
    return worker;
}

deinit :: (using worker: *Proxy_Worker_Ctx) {
    if state != .COMPLETE || state != .ERROR return;

    if proxy_socket_fd != -1  POSIX.close(proxy_socket_fd);
    if client_socket_fd != -1 POSIX.close(proxy_socket_fd);

    if request free(request,, allocator);
    free(worker,, allocator);
}

proxy_worker_process :: (ev_loop: *Event_Loop.Event_Loop, event_data: *Event_Loop.Event_Data) {
    ctx := cast(*Proxy_Worker_Ctx) event_data.ctx;
    mark := get_temporary_storage_mark();
    defer   set_temporary_storage_mark(mark);

    if ctx.state == {
        case .WAITING_FOR_CLIENT_REQ;
            success, request := Http.http_read_request(ctx.client_socket_fd);
            ctx.request = *request;

            proxy_socket_fd := Socket.socket(Socket.AF_INET, .STREAM, 0);
            if proxy_socket_fd == -1 {
                log_error("socket creation failed: %", System.get_error_string(POSIX.errno()));
                ctx.state = .ERROR;
            }
            set_nonblocking(proxy_socket_fd);

            proxy_addr: Socket.sockaddr_in;
            proxy_addr.sin_family = Socket.AF_INET;
            proxy_addr.sin_port   = Socket.htons(9999);
            Socket.inet_pton(Socket.AF_INET, "127.0.0.1", *proxy_addr.sin_addr);

            connect_result := Socket.connect(proxy_socket_fd, xx *proxy_addr, size_of(Socket.sockaddr_in));
            if connect_result == -1 && POSIX.errno() != POSIX.EINPROGRESS {
                log_error("connect failed: %", System.get_error_string(POSIX.errno()));
                ctx.state = .ERROR;
            } else {
                Event_Loop.evl_register(ev_loop, proxy_socket_fd, .WRITE, event_data, one_shot = true);
            }
        case .WAITING_FOR_PROXY_WRITE;
            http_res := Http.http_init_res();
            defer Http.http_resp_deinit(*http_res);
            Http.http_resp_set_status_code(*http_res, .OK);
            Http.http_res_add_header(*http_res, "Content-Type", "text/plain");
            Http.http_res_set_body(*http_res, "Hello, HTTP!!!");
            bytes := Http.http_res_to_bytes(*http_res);
            defer free(bytes.data,, http_res.allocator);

            if Socket.send(ctx.proxy_socket_fd, bytes.data, xx bytes.count, 0) == -1 {
                log_error("send failed: %", System.get_error_string(POSIX.errno()));
                ctx.state = .ERROR;
            } else {
                Event_Loop.evl_register(ev_loop, ctx.proxy_socket_fd, .READ, event_data, one_shot = true);
            }
        case .WAITING_FOR_PROXY_READ;
            // _, resp := Http.http_read_response(ctx.proxy_socket_fd);
            // defer Http.http_deinit(*resp);
            socket_reader: Http.Socket_Reader = .{socket_fd = ctx.proxy_socket_fd, allocator = context.allocator};
            resp: Http.Http_Response;
            Http.http_parse_response(*resp, *socket_reader);

            bytes := Http.to_bytes_array(*resp);
            defer free(bytes.data,, resp.allocator);


            if Socket.send(ctx.proxy_socket_fd, bytes.data, xx bytes.count, 0) == -1 {
                log_error("send failed: %", System.get_error_string(POSIX.errno()));
                ctx.state = .ERROR;
            } else {
                Event_Loop.evl_unregister(evl_loop, ctx.proxy_socket_fd, .READ, event_data, one_shot = true);
            }
            ctx.state = .COMPLETE;
    }
    handle_state_transition(ctx);
    if ctx.state == .ERROR || ctx.state == .COMPLETE  Event_Loop.deinit(event_data);
}

Proxy_Worker_State :: enum {
    WAITING_FOR_CLIENT_REQ;
    WAITING_FOR_PROXY_WRITE;
    WAITING_FOR_PROXY_READ;
    COMPLETE;
    ERROR;
}


#scope_file

Proxy_Worker_Ctx :: struct {
    master_socket_fd : s32 = -1; // server socket where client connection will be accepted
    client_socket_fd : s32 = -1; // client socket where data will be read from and written to
    proxy_socket_fd  : s32 = -1; // proxy server socket where data will be read from and written to
    state            : Proxy_Worker_State = .WAITING_FOR_CLIENT_REQ;

    request          : *Http.Http_Request = null;

    allocator        : Allocator;
}

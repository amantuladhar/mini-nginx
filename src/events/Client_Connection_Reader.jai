create_client_request_reader :: (client_socket_fd: s32) -> *Event_Loop.Event_Data {
    data := New(Client_Request_Reader_EData);
    data.* = .{ client_socket_fd };
    request_reader := New(Event_Loop.Event_Data);
    request_reader.* = .{ data, client_request_read };
    return request_reader;
}

Client_Request_Reader_EData :: struct {
    socket_fd: s32; // client socket where data will be read from and written to
    state: Proxy_Worker_State = .WAITING_FOR_CLIENT_READ;
    request: *Http.Http_Request;
    proxy_fd: s32 = -1;
}

Proxy_Worker_State :: enum {
    WAITING_FOR_CLIENT_READ;
    WAITING_FOR_PROXY_WRITE;
    WAITING_FOR_PROXY_READ;
    COMPLETE;
    ERROR;
}


client_request_read :: (ev_loop: *Event_Loop.Event_Loop, event_data: *Event_Loop.Event_Data)  {

    ctx := cast(*Client_Request_Reader_EData) event_data.ctx;
    client_socket_fd := ctx.*.socket_fd;
    log("Client request reader called: fd = %, event_loop: %", client_socket_fd, ev_loop.*);
    state := ctx.*.state;

    flag := true;
    while brk: flag {
        flag = false;
        if state == {
            case .WAITING_FOR_CLIENT_READ;
                defer Event_Loop.evl_unregister(ev_loop, client_socket_fd, .READ);
                success, request := Http.http_parse_request(client_socket_fd);
                if !success {
                    ctx.*.state = .ERROR;
                    log_error("Failed to read HTTP request");
                    break :brk;
                }
                ctx.*.request = request;
                ctx.*.state = .WAITING_FOR_PROXY_WRITE;

                proxy_addr := "127.0.0.1";
                proxy_port : u16 = 9999;
                proxy_fd := Socket.socket(Socket.AF_INET, .STREAM, 0);
                // @todo - close socket
                if proxy_fd == -1 {
                    log_error("socket creation failed: %", System.get_error_string(POSIX.errno()));
                    exit(1);
                }
                ctx.*.proxy_fd = proxy_fd;
                set_nonblocking(proxy_fd);
                address := Socket.sockaddr_in.{
                    sin_family = Socket.AF_INET,
                    sin_addr = Socket.in_addr.{ s_addr = Socket.inet_addr(proxy_addr.data) },
                    sin_port = Socket.htons(proxy_port),
                };
                proxy_connect_result :=Socket.connect(proxy_fd, xx *address, size_of(Socket.sockaddr_in));
                if  proxy_connect_result == -1 && proxy_connect_result != POSIX.EINPROGRESS {
                        log_error("connect failed: %", System.get_error_string(POSIX.errno()));
                } else {
                    log("Connected to proxy at %:%", proxy_addr, proxy_port);
                    ctx.*.state = .WAITING_FOR_PROXY_READ;
                }
                }
            case .WAITING_FOR_PROXY_WRITE;
                proxy_send_count := Socket.send(proxy_fd, request.socket_reader.buffer.data,        xx                 request.socket_reader.buffer.count, 0);
                log("Number of bytes send to proxy - %", proxy_send_count);
                if proxy_send_count == -1 {
                    log_error("proxy send failed: %", System.get_error_string(POSIX.errno()));
                    return;
                } else {
                    ctx.*.state = .WAITING_FOR_PROXY_READ;
                }
            case .WAITING_FOR_PROXY_READ;
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
            case .COMPLETE;
            case .ERROR;
        }
    }
}

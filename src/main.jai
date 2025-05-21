PORT :: 8080;
BUFFER_SIZE :: 1024;

main :: () {
    defer { report_memory_leaks(); };

    server_fd := Socket.socket(Socket.AF_INET, .STREAM, 0);
    if server_fd == -1 {
        log_error("socker creation failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }
    defer POSIX.close(server_fd);

    opt := 1;
    if Socket.setsockopt(server_fd, Socket.SOL_SOCKET, Socket.SO_REUSEADDR , *opt, size_of(int)) {
        log_error("setsockopt failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }

    address := Socket.sockaddr_in.{
        sin_family = Socket.AF_INET,
        sin_addr = Socket.in_addr.{ s_addr = Socket.INADDR_ANY},
        sin_port = Socket.htons(PORT),
    };

    host := "127.0.0.1";
    if Socket.bind(server_fd, cast(*Socket.sockaddr, *address), size_of(type_of(address))) == -1 {
        log_error("bind failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }
    number_of_backlog_connections : s32 = 3;
    if Socket.listen(server_fd, number_of_backlog_connections) == -1 {
        log_error("listen failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }
    log("Listening on port %", PORT);

    // while true {
        log("Waiting for new connection...");
        client_addr: Socket.sockaddr_in;
        addr_len: Socket.socklen_t = size_of(Socket.sockaddr_in);
        client_socket_fd := Socket.accept(server_fd, cast(*Socket.sockaddr, *client_addr), *addr_len);
        if client_socket_fd == -1 {
            log_error("accept failed: %", System.get_error_string(POSIX.errno()));
            exit(1);
            // continue;
        }
        defer POSIX.close(client_socket_fd);

        buffer : [BUFFER_SIZE]u8;
        readcount := POSIX.read(client_socket_fd, buffer.data, BUFFER_SIZE -1);
        if readcount == -1 {
            log_error("read failed: %", System.get_error_string(POSIX.errno()));
            exit(1);
            // continue;
        }
        if readcount == 0 {
            log("Client disconnected: %", System.get_error_string(POSIX.errno()));
            exit(1);
            // continue;
        }
        log("Received: %", to_string(buffer.data, readcount));
        hello := "hello";
        if Socket.send(client_socket_fd, hello.data, xx hello.count, 0) == -1 {
            log_error("send failed: %", System.get_error_string(POSIX.errno()));
            exit(1);
            // continue;
        }
        log("Sent: hello");
    // }
}

#import "Basic"()(MEMORY_DEBUGGER=true);
Socket :: #import "Socket";
System :: #import "System";
POSIX :: #import "POSIX";
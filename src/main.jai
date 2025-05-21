PORT :: 8080;
BUFFER_SIZE :: 1024;

Process_Type :: enum {
    PARENT;
    CHILD;
}

main :: () {
    defer { report_memory_leaks(); };
    logger_data := Custom_Logger_Data.{ .PARENT, POSIX.getpid() };
    context.logger = custom_logger;
    context.logger_data = *logger_data;

    run_master_process();
}

run_master_process :: () {
    listener_socket_fd := setup_listener(PORT);
    defer POSIX.close(listener_socket_fd);

    pid := POSIX.fork();
    if pid == {
        case -1;
            log_error("fork failed: %", System.get_error_string(POSIX.errno()));
            exit(1);
        case 0;
            logger_data := Custom_Logger_Data.{ .CHILD, POSIX.getpid() };
            context.logger_data = *logger_data;
            run_child_process(listener_socket_fd);
            exit(0);
        case;
            log("I have a baibeeee.... I am gonna call you - %", pid);
            POSIX.waitpid(pid, null, 0);
    }
}


run_child_process :: (listener_socket_fd: s32) {
    handle_connection(listener_socket_fd);
}

setup_listener :: (port: int) -> s32 {
    listener_socket_fd := Socket.socket(Socket.AF_INET, .STREAM, 0);
    if listener_socket_fd == -1 {
        log_error("socket creation failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }

    opt := 1;
    if Socket.setsockopt(listener_socket_fd, Socket.SOL_SOCKET, Socket.SO_REUSEADDR , *opt, size_of(int)) {
        log_error("setsockopt failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }

    address := Socket.sockaddr_in.{
        sin_family = Socket.AF_INET,
        sin_addr = Socket.in_addr.{ s_addr = Socket.INADDR_ANY},
        sin_port = Socket.htons(PORT),
    };

    host := "127.0.0.1";
    if Socket.bind(listener_socket_fd, cast(*Socket.sockaddr, *address), size_of(type_of(address))) == -1 {
        log_error("bind failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }
    number_of_backlog_connections : s32 = 3;
    if Socket.listen(listener_socket_fd, number_of_backlog_connections) == -1 {
        log_error("listen failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }
    log("Listening on port %", PORT);
    return listener_socket_fd;
}

handle_connection :: (listener_socket_fd: s32) {
    while true {
        log("Waiting for new connection...");
        client_addr: Socket.sockaddr_in;
        addr_len: Socket.socklen_t = size_of(Socket.sockaddr_in);
        client_socket_fd := Socket.accept(listener_socket_fd, cast(*Socket.sockaddr, *client_addr), *addr_len);
        if client_socket_fd == -1 {
            log_error("accept failed: %", System.get_error_string(POSIX.errno()));
            continue;
        }
        defer POSIX.close(client_socket_fd);

        buffer : [BUFFER_SIZE]u8;
        read_count := POSIX.read(client_socket_fd, buffer.data, BUFFER_SIZE -1);
        if read_count == -1 {
            log_error("read failed: %", System.get_error_string(POSIX.errno()));
            continue;
        }
        if read_count == 0 {
            log("Client disconnected: %", System.get_error_string(POSIX.errno()));
            continue;
        }
        log("Received: %", to_string(buffer.data, read_count));
        hello := "hello";
        if Socket.send(client_socket_fd, hello.data, xx hello.count, 0) == -1 {
            log_error("send failed: %", System.get_error_string(POSIX.errno()));
            continue;
        }
        log("Sent: hello");
    }
}

Custom_Logger_Data :: struct {
    process_type: Process_Type;
    pid: s32;
};

custom_logger :: (message: string, data: *void, info: Log_Info) {
    mark := get_temporary_storage_mark();
    defer   set_temporary_storage_mark(mark);
    using logger_data := cast(*Custom_Logger_Data, data);
    msg := tprint("[%:%] %\n", process_type, pid, message);
    write_string(msg);
}

#import "Basic"()(MEMORY_DEBUGGER=true);
Socket :: #import "Socket";
System :: #import "System";
POSIX :: #import "POSIX";
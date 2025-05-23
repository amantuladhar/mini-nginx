PORT :: 8080;
BUFFER_SIZE :: 1024;

Process_Type :: enum {
    PARENT;
    CHILD;
}

// @note
// Global variables are bad (maybe), but I am not doing multithreading in this example
// I am using fork() to create multiple child process, and each child will close this memory
// so maybe for this situation this is not a problem
child_pids: [..]s32;
running   := true;
fork      := true;

master_shutdown_handler:: (sig: s32, info: *POSIX.siginfo_t, ctx: *void) #c_call {
    push_context {
        log("[%]: Signal handler called: % - Setting running=false\n", POSIX.getpid(), sig);
        running = false;
        log("[%]: running is now %\n", POSIX.getpid(), running);
    }
}

setup_graceful_shutdown_handler :: () {
    sa: POSIX.sigaction_t;
    sa.sa_sigaction = master_shutdown_handler;
    POSIX.sigemptyset(*sa.sa_mask);
    sa.sa_flags = POSIX.SA_SIGINFO;

    POSIX.sigaction(POSIX.SIGTERM, *sa, null);
    POSIX.sigaction(POSIX.SIGKILL, *sa, null);
    POSIX.sigaction(POSIX.SIGINT, *sa, null);
}


main :: () {
    defer { report_memory_leaks(); };

    logger_data := Custom_Logger_Data.{ .PARENT, POSIX.getpid() };
    context.logger = custom_logger;
    context.logger_data = *logger_data;

    master_main_loop();
    log("Master process has shutdown");
}

master_main_loop :: () {
    setup_graceful_shutdown_handler();
    listener_socket_fd := setup_listener(PORT);
    defer POSIX.close(listener_socket_fd);

    // @investigate
    // What happens to memory allocated in the child process?
    // does memory debugger catch them?
    if !fork worker_main_loop(listener_socket_fd);
    else {
        pid := POSIX.fork();
        if pid == {
            case 0;
                logger_data := Custom_Logger_Data.{ .CHILD, POSIX.getpid() };
                context.logger_data = *logger_data;
                worker_main_loop(listener_socket_fd);
                log("Child process has stopped.");
                exit(0);
            case -1;
                log_error("fork failed: %", System.get_error_string(POSIX.errno()));
                exit(1);
            case;
                log("I now have a child process and its pid is %", pid);
                array_add(*child_pids, pid);
                log("Waiting for child process to complete....");
                while true && child_pids.count > 0 {
                    result := POSIX.waitpid(-1, null, POSIX.WNOHANG);
                    if result == {
                        case 0; // none have shutdown
                            POSIX.usleep(1 * 1000_000);
                        case -1;
                            error := POSIX.errno();
                            // @note
                            // My understanding here is because of signal interrupt handler
                            // control flow goes to the sig handler, this retuns right away with EINTR error code
                            if error == POSIX.EINTR continue;
                            log_error("waitpid failed: %", System.get_error_string(error));
                        case;
                            log("pid = % - shutdown successfully.", result);
                            array_unordered_remove_by_value(*child_pids, result);
                    }
                }
                log("Waiting complete. All child process is now dead.");
        }
    }
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

    set_nonblocking(listener_socket_fd);

    return listener_socket_fd;
}

set_nonblocking :: (socket_fd: s32) {
    flags := POSIX.fcntl(socket_fd, POSIX.F_GETFL, 0);
    if flags == -1 {
        log_error("fcntl failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }
    if POSIX.fcntl(socket_fd, POSIX.F_SETFL, flags | POSIX.O_NONBLOCK) == -1 {
        log_error("fcntl failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }
}

worker_main_loop :: (listener_socket_fd: s32) {
    ev_loop := queue_init();
    log("Event loop initialized: %", ev_loop);
    defer queue_deinit(*ev_loop);



    data := New(Client_Conn_Acceptor_EData);
    data.* = .{ listener_socket_fd };

    conn_accept_edata := New(Event_Data);
    conn_accept_edata.* = .{ data, connection_acceptor };
    queue_register(*ev_loop, listener_socket_fd, .READ, conn_accept_edata);

    events: [10]Event;
    while running {
        defer {
            // Adding 1 second delay for debugging - remove later
            POSIX.usleep(1000_000);
        }
        log("Polling for events... event_loop: %", ev_loop);
        n_events := queue_poll(ev_loop, *events);
        if n_events == -1 {
            log_error("poll failed: %", System.get_error_string(POSIX.errno()));
            continue;
        }
        log("Number of events: %", n_events);
        for event: array_view(events, 0, n_events) {
            event_data: *Event_Data = parse_event_data(*event);
            event_data.callback(*ev_loop, event_data);
        }
    }
}

Client_Conn_Acceptor_EData :: struct {
    // server socket where connection will be accepted
    socket_fd: s32;
}

connection_acceptor :: (ev_loop: *Event_Loop, event_data: *Event_Data) {
    ctx := cast(*Client_Conn_Acceptor_EData, event_data.ctx);
    listener_socket_fd := ctx.*.socket_fd;
    log("Connection acceptor called. fd = %, event_loop: %", listener_socket_fd, ev_loop.*);

    client_addr: Socket.sockaddr_in;
    addr_len: Socket.socklen_t = size_of(Socket.sockaddr_in);

    client_socket_fd := Socket.accept(listener_socket_fd, cast(*Socket.sockaddr, *client_addr), *addr_len);
    if client_socket_fd == -1 {
        log_error("accept failed: %", System.get_error_string(POSIX.errno()));
        return;
    }

    array_add(*ev_loop.registered_fds, client_socket_fd);

    data := New(Client_Request_Reader_EData);
    data.* = .{ client_socket_fd };
    client_req_reader_edata := New(Event_Data);
    client_req_reader_edata.* = .{ data, client_request_read };
    queue_register(ev_loop, client_socket_fd, .READ, client_req_reader_edata);
    log("Accepted connection from %:%", to_string(Socket.inet_ntoa(client_addr.sin_addr)), Socket.ntohs(client_addr.sin_port));
}
Client_Request_Reader_EData :: struct {
    // client socket where data will be read from and written to
    socket_fd: s32;
}

client_request_read :: (ev_loop: *Event_Loop, event_data: *Event_Data)  {
    ctx := cast(*Client_Request_Reader_EData, event_data.ctx);
    client_socket_fd := ctx.*.socket_fd;
    log("Client request reader called: fd = %, event_loop: %", client_socket_fd, ev_loop.*);

    defer {
        log("Cleaning up resources for fd = %", client_socket_fd);
        queue_unregister(ev_loop, client_socket_fd, .READ);
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
    log("Received: %", to_string(buffer.data, read_count));
    hello := "hello";
    if Socket.send(client_socket_fd, hello.data, xx hello.count, 0) == -1 {
        log_error("send failed: %", System.get_error_string(POSIX.errno()));
        return;
    }
    log("Sent: hello");
}

#import "Basic"()(MEMORY_DEBUGGER=true);
Socket :: #import "Socket";
System :: #import "System";
POSIX :: #import "POSIX";
#load "custom_logger.jai";
#load "event_loop.jai";

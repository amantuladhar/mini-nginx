master_main_loop :: () {
    set_shutdown_handler(shutdown_handler);
    master_socket_fd := setup_master_listener(PORT);
    defer POSIX.close(master_socket_fd);

    if !fork worker_main_loop(master_socket_fd, 0);
    else {
        // @investigate
        // What happens to memory allocated in the child process?
        // does memory debugger catch them?
        master_fork_process(master_socket_fd);
        master_wait_for_fork_process();
    }
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


#scope_file

master_fork_process :: (master_socket_fd: s32) {
    logger_data := cast(*Custom_Logger_Data) context.logger_data;
    assert(logger_data.*.process_type == .PARENT, "This method should only be called from parent process");
    for fork_counter: 0..fork-1 {
        pid := POSIX.fork();
        if pid == {
            case 0;
                logger_data := Custom_Logger_Data.{ .CHILD, POSIX.getpid() };
                context.logger_data = *logger_data;
                worker_main_loop(master_socket_fd, fork_counter);
                log("Child process has stopped.");
                exit(0);
            case -1;
                log_error("fork failed: %", System.get_error_string(POSIX.errno()));
                exit(1);
            case;
                log("I now have a child process and its pid is %", pid);
                array_add(*child_pids, pid);
            }
    }
}

shutdown_handler:: (sig: s32, info: *POSIX.siginfo_t, ctx: *void) #c_call {
    push_context {
        log("[%]: Signal handler called", POSIX.getpid());
        running = false;
    }
}

master_wait_for_fork_process :: () {
    logger_data := cast(*Custom_Logger_Data, context.logger_data);
    assert(logger_data.*.process_type == .PARENT, "This method should only be called from parent process");
    log("Waiting for child process to complete....");
    while child_pids.count > 0 {
        result := POSIX.waitpid(-1, null, POSIX.WNOHANG);
        if result == {
            case 0; // none have shutdown
                POSIX.usleep(1 * 1000_000);
            case -1;
                // @todo
                // We need to check if the child process was shutdown by signal
                // Maybe we need to check status code and if it is not 0 we need to respawn
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

setup_master_listener :: (port: int) -> s32 {
    logger_data := cast(*Custom_Logger_Data, context.logger_data);
    assert(logger_data.*.process_type == .PARENT, "This method should only be called from parent process");

    master_socket_fd := Socket.socket(Socket.AF_INET, .STREAM, 0);
    if master_socket_fd == -1 {
        log_error("socket creation failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }

    opt := 1;
    if Socket.setsockopt(master_socket_fd, Socket.SOL_SOCKET, Socket.SO_REUSEADDR , *opt, size_of(int)) {
        log_error("setsockopt failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }

    address := Socket.sockaddr_in.{
        sin_family = Socket.AF_INET,
        sin_addr = Socket.in_addr.{ s_addr = Socket.INADDR_ANY},
        sin_port = Socket.htons(PORT),
    };

    if Socket.bind(master_socket_fd, cast(*Socket.sockaddr, *address), size_of(type_of(address))) == -1 {
        log_error("bind failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }
    number_of_backlog_connections : s32 = 3;
    if Socket.listen(master_socket_fd, number_of_backlog_connections) == -1 {
        log_error("listen failed: %", System.get_error_string(POSIX.errno()));
        exit(1);
    }
    log("Listening on port %", PORT);

    set_nonblocking(master_socket_fd);

    return master_socket_fd;
}

worker_main_loop :: (master_socket_fd: s32, fork_counter: int) {
    ev_loop := Event_Loop.evl_init();
    log("Event loop initialized: %", ev_loop);
    defer Event_Loop.evl_deinit(*ev_loop);

    // @todo
    // CPU Affinity - on linux might be easier
    // but on mac it is bit tricky
    // MAC has something called QoS which we can use to set priority
    // AFAIK we can't assign specific CPU for a given process on mac

    conn_acceptor := create_client_connection_acceptor(master_socket_fd);
    defer Event_Loop.evl_deinit_event_data(conn_acceptor);
    Event_Loop.evl_register(*ev_loop, master_socket_fd, .READ, conn_acceptor);

    events: [10]Event_Loop.Event;
    while running {
        log("Polling for events... event_loop: %", ev_loop);
        n_events := Event_Loop.evl_poll(ev_loop, *events);
        if n_events == -1 {
            // @todo
            // Check if error happened because control flow was moved to signal handler
            // if yes, just do continue
            log_error("poll failed:(%) %", POSIX.errno(), System.get_error_string(POSIX.errno()));
            continue;
        }
        log("Number of events: %", n_events);
        for event: array_view(events, 0, n_events) {
            event_data := Event_Loop.evl_get_event_data(*event);
            event_data.callback(*ev_loop, event_data);
        }
    }
}

#scope_file

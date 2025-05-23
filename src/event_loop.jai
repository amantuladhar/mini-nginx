Event_Loop :: struct {
    event_fd: s32;
    registered_fds: [..]s32;
}

Event_Interest :: enum s16 {
    #if OS == {
        case .LINUX;
            READ :: Linux.EPOLLIN | Linux.EPOLLET;
        case .MACOS;
            READ :: MacOS.Kevent_Filter.READ;
        case;
            #assert(false, "Unsupported OS");
    }
}

Event_Data :: struct {
    ctx: *void;
    callback: (event_loop: *Event_Loop, event_data: *Event_Data);
}

#if OS == {
    case .LINUX;
        Event :: Linux.epoll_event;
    case .MACOS;
        Event :: MacOS.Kevent64;
    case;
        #assert(false, "Unsupported OS");
}

queue_init :: () -> Event_Loop {
    return .{ event_fd = _create_queue() };
}

queue_deinit :: (ev: *Event_Loop) {
    #if OS == {
        case .LINUX;
            POSIX.close(ev.event_fd);
        case .MACOS;
            POSIX.close(ev.event_fd);
        case;
            #assert(false, "Unsupported OS");
    }
    free(ev.registered_fds.data);
}

queue_register :: (ev: *Event_Loop, which_fd: s32, interest: Event_Interest, event_data: *Event_Data) {
    #if OS == {
        case .LINUX;
            #assert(false, "Not implemented yet");
        case .MACOS;
            changelist: [1]Event = .[
                .{
                    ident = xx which_fd,
                    filter = xx interest,
                    flags = MacOS.Kevent_Flags.ADD | MacOS.Kevent_Flags.ENABLE,
                    fflags = 0,
                    data = 0,
                    udata = cast(*void, event_data),
                }
            ];
            events: [0]Event;
            MacOS.kevent64(ev.event_fd, changelist.data, 1, events.data, 0, .KEVENT_FLAG_NONE, null);
        case;
            #assert(false, "Unsupported OS");
    }
}

queue_unregister :: (ev: *Event_Loop, which_fd: s32, interest: Event_Interest) {
    #if OS == {
        case .LINUX;
            #assert(false, "Not implemented yet");
        case .MACOS;
            changelist: [1]Event = .[
                .{
                    ident = xx which_fd,
                    filter = xx interest,
                    flags = MacOS.Kevent_Flags.DELETE | MacOS.Kevent_Flags.DISABLE,
                    fflags = 0,
                    data = 0,
                    udata = null,
                }
            ];
            events: [0]Event;
            MacOS.kevent64(ev.event_fd, changelist.data,1, events.data,0, .KEVENT_FLAG_NONE,null);
        case;
            #assert(false, "Unsupported OS");
    }
}

parse_event_data :: (event: Event) -> *Event_Data {
    #if OS == {
        case .MACOS;
            event_data := cast(*Event_Data, event.udata);
            return event_data;
        case .LINUX;
            #assert(false, "Not implemented yet");
        case;
            #assert(false, "Unsupported OS");
    }
}

queue_poll :: (ev: Event_Loop, events: *[10]Event) -> int {
    #if OS == {
        case .MACOS;
            n_events := MacOS.kevent64(ev.event_fd, null, 0, events.data, events.count, .KEVENT_FLAG_NONE, null);
            return n_events;
        case .LINUX;
            #assert(false, "Not implemented yet");
        case;
            #assert(false, "Unsupported OS");
    }
}



Posix :: #import "POSIX";
#if OS == {
    case .MACOS;
        MacOS :: #import "MacOS";
    case .LINUX;
        Linux :: #import "Linux";
    case;
}

#scope_file

_create_queue :: () -> s32 {
    #if OS == {
        case .MACOS;
            return MacOS.kqueue();
        case .LINUX;
            return Posix.epoll_create1(0);
        case;
            #assert(false, "Unsupported OS");
    }
}

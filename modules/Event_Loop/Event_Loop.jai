Event_Loop :: struct {
    evl_queue_fd: s32;
    registered_fds: [..]s32;
}

Event_Topic :: enum s16 {
    #if OS == {
        case .LINUX;
            READ :: Linux.EPOLLIN | Linux.EPOLLET;
        case .MACOS;
            READ :: MacOS.Kevent_Filter.READ;
        case;
            #assert(false, "Unsupported OS");
    }
}

#if OS == {
    case .LINUX;
        Event :: Linux.epoll_event;
    case .MACOS;
        Event :: MacOS.Kevent64;
    case;
        #assert(false, "Unsupported OS");
}

// @todo
// Maybe I need to store reference to allocator here?
Event_Data :: struct {
    ctx: *void;
    callback: (event_loop: *Event_Loop, event_data: *Event_Data);
}

evl_deinit_event_data :: (using edata: *Event_Data) {
    free(ctx);
    free(edata);
}

evl_init :: () -> Event_Loop {
    return .{ evl_queue_fd = evl_init_queue() };
}

evl_deinit :: (ev: *Event_Loop) {
    #if OS == {
        case .LINUX;
            POSIX.close(ev.evl_queue_fd);
        case .MACOS;
            POSIX.close(ev.evl_queue_fd);
        case;
            #assert(false, "Unsupported OS");
    }
    free(ev.registered_fds.data);
}

evl_register :: (ev: *Event_Loop, which_fd: s32, topic: Event_Topic, event_data: *Event_Data) {
    #if OS == {
        case .LINUX;
            #assert(false, "Not implemented yet");
        case .MACOS;
            changelist: [1]Event = .[
                .{
                    ident = xx which_fd,
                    filter = xx topic,
                    flags = MacOS.Kevent_Flags.ADD | MacOS.Kevent_Flags.ENABLE,
                    fflags = 0,
                    data = 0,
                    udata = cast(*void, event_data),
                }
            ];
            events: [0]Event;
            MacOS.kevent64(ev.evl_queue_fd, changelist.data, 1, events.data, 0, .KEVENT_FLAG_NONE, null);
        case;
            #assert(false, "Unsupported OS");
    }
}

evl_unregister :: (ev: *Event_Loop, which_fd: s32, topic: Event_Topic) {
    #if OS == {
        case .LINUX;
            #assert(false, "Not implemented yet");
        case .MACOS;
            changelist: [1]Event = .[
                .{
                    ident = xx which_fd,
                    filter = xx topic,
                    flags = MacOS.Kevent_Flags.DELETE | MacOS.Kevent_Flags.DISABLE,
                    fflags = 0,
                    data = 0,
                    udata = null,
                }
            ];
            events: [0]Event;
            MacOS.kevent64(ev.evl_queue_fd, changelist.data,1, events.data,0, .KEVENT_FLAG_NONE,null);
        case;
            #assert(false, "Unsupported OS");
    }
}

evl_get_event_data :: (event: Event) -> *Event_Data {
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

evl_poll :: (ev: Event_Loop, events: *[10]Event) -> int {
    #if OS == {
        case .MACOS;
            n_events := MacOS.kevent64(ev.evl_queue_fd, null, 0, events.data, events.count, .KEVENT_FLAG_NONE, null);
            return n_events;
        case .LINUX;
            #assert(false, "Not implemented yet");
        case;
            #assert(false, "Unsupported OS");
    }
}

#scope_module

evl_init_queue :: () -> s32 {
    #if OS == {
        case .MACOS;
            return MacOS.kqueue();
        case .LINUX;
            return Posix.epoll_create1(0);
        case;
            #assert(false, "Unsupported OS");
    }
}

#import "Basic";
POSIX :: #import "POSIX";
#if OS == {
    case .MACOS;
        MacOS :: #import "MacOS";
    case .LINUX;
        Linux :: #import "Linux";
    case;
}

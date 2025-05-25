set_shutdown_handler :: (cb: (sig: s32, info: *POSIX.siginfo_t, ctx: *void) #c_call) {
    sa: POSIX.sigaction_t;
    sa.sa_sigaction = cb;
    POSIX.sigemptyset(*sa.sa_mask);
    sa.sa_flags = POSIX.SA_SIGINFO;

    POSIX.sigaction(POSIX.SIGTERM, *sa, null);
    POSIX.sigaction(POSIX.SIGKILL, *sa, null);
    POSIX.sigaction(POSIX.SIGINT, *sa, null);
}

shutdown_handler_log :: (sig: s32, info: *POSIX.siginfo_t, ctx: *void) #c_call {
    push_context {
        log("Received shutdown signal\n");
    }
}

#scope_module

#import "Basic";
POSIX :: #import "POSIX";

PORT :: 8080;
BUFFER_SIZE :: 1024;

Process_Type :: enum { PARENT; CHILD; }

// @note
// Global variables are bad (maybe), but I am not doing multithreading in this example
// I am using fork() to create multiple child process, and each child will close this memory
// so maybe for this situation this is not a problem
child_pids: [..]s32;
running   := true;
fork      := 0; // 0 for just on process, > 0 for n worker processes

main :: () {
    defer { reset_temporary_storage(); report_memory_leaks(); }

    logger_data := Custom_Logger_Data.{ .PARENT, POSIX.getpid() };
    context.logger = custom_logger;
    context.logger_data = *logger_data;

    master_main_loop();
    log("Master process has shutdown");
}


#import "Basic"()(MEMORY_DEBUGGER=true);
#import "Graceful_Shutdown";

Socket        :: #import "Socket";
System        :: #import "System";
POSIX         :: #import "POSIX";
Event_Loop    :: #import "Event_Loop";
Http          :: #import "Http";
Hash_Table    :: #import "Hash_Table";

#load "master.jai";
#load "worker.jai";
#load "events/Client_Connection_Acceptor.jai";
#load "events/Client_Connection_Reader.jai";
#load "custom_logger.jai";

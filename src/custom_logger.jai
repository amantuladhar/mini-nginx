Custom_Logger_Data :: struct {
    process_type: Process_Type;
    pid: s32;
};

custom_logger :: (message: string, data: *void, info: Log_Info) {
    mark := get_temporary_storage_mark();
    defer   set_temporary_storage_mark(mark);
    using logger_data := cast(*Custom_Logger_Data, data);
    msg := tprint("[%:%:%] %\n", process_type, pid, cast(u64, POSIX.pthread_self()), message);
    write_string(msg);
}

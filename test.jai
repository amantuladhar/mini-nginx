main :: () {
    proxy_addr := "127.0.0.1";
    proxy_port : u16 = 9999;

    proxy_fd := socket(AF_INET, .STREAM, 0);
    if proxy_fd == -1 {
        log_error("socket creation failed: %", get_error_string(errno()));
        exit(1);
    }
    defer close(proxy_fd);

    address := sockaddr_in.{
        sin_family = AF_INET,
        sin_addr = in_addr.{ s_addr = inet_addr(proxy_addr.data) },
        sin_port = htons(proxy_port),
    };
    proxy_connect_result := connect(proxy_fd, xx *address, size_of(sockaddr_in));
    if  proxy_connect_result == -1 {
        log_error("connect failed: %", get_error_string(errno()));
        return;
    }

    builder: String_Builder;
    init_string_builder(*builder);
    append(*builder, "GET / HTTP/1.1\r\n");
    append(*builder, "Host: 127.0.0.1:9999\r\n");
    append(*builder, "Accept: */*\r\n");
    append(*builder, "\r\n");

    proxy_req := builder_to_string(*builder);
    log("proxy_req: %", proxy_req);
    defer free(proxy_req);

    proxy_send_count :=  send(proxy_fd, proxy_req.data, xx proxy_req.count, 0);

    log("Number of bytes send to proxy - %", proxy_send_count);
    if proxy_send_count == -1 {
        log_error("proxy send failed: %", get_error_string(errno()));
        return;
    }

    buffer: [4096]u8;
    read_count := read(proxy_fd, buffer.data, buffer.count);
    if read_count == -1 {
        log_error("read failed: %", get_error_string(errno()));
        return;
    }
    log("read_count from proxy: %", read_count);
    log("Received from proxy: <\n%\n>", string.{buffer.count, buffer.data});
}

#run build();

build :: () {
    set_build_options_dc(.{do_output=false, output_path="out", output_executable_name="target"});
    main();
}

#import "Compiler";
#import "Basic";
#import "Socket";
#import "POSIX";
#import "System";
#import "String";

Http_Request :: struct {
    // version : Assuming 1.1 for now
    method          : Http_Method;
    path            : string;
    headers         : Headers;
    body            : []u8;
    socket_reader   : Socket_Reader;
}

Http_Response :: struct {
    status_code : Http_Status_Code;
    headers     : Headers;
    body        : []u8;
    allocator   : Allocator;
}

Http_Status_Code :: enum u16 #specified {
    OK                      :: 200;
    CREATED                 :: 201;
    ACCEPTED                :: 202;
    NO_CONTENT              :: 204;

    BAD_REQUEST             :: 400;
    UNAUTHORIZED            :: 401;
    FORBIDDEN               :: 403;
    NOT_FOUND               :: 404;

    INTERNAL_SERVER_ERROR   :: 500;
}

Headers :: Hash_Table.Table(string, string);

Http_Method :: enum {
    GET;
    POST;
    PUT;
    DELETE;
    PATCH;
}

http_deinit :: (using req: *Http_Request) {
    Hash_Table.deinit(*headers);
    socket_reader_deinit(*socket_reader);
}

http_resp_set_status_code :: (resp: *Http_Response, status_code: Http_Status_Code) {
   resp.status_code = status_code;
}

http_read_response :: (socket_fd: s32) -> success: bool = true, resp: Http_Response {
    reader := socket_reader_init(socket_fd);
}

http_parse_request :: (socket_fd: s32) -> success: bool = true, req: Http_Request {
    reader := socket_reader_init(socket_fd);

    _, status_line := read_until(*reader, "\n");
    method_i       := find_index(status_line, " ", 0);
    path_i         := find_index(status_line, " ", start = method_i + 1);

    headers: Headers;
    Hash_Table.init(*headers);

    while true {
        _, header_line := read_until(*reader, "\n");
        if string.{2, header_line.data} == "\r\n" break;

        key_i := find_index(header_line, ":", 0);
        key   := String.trim(string.{key_i, header_line.data});
        value := String.trim(string.{header_line.count - key_i - 1, header_line.data + key_i + 1});

        Hash_Table.table_set(*headers, key, value);
    }
    content_length_str := Hash_Table.table_find_pointer(*headers, "Content-Length");
    body: []u8 = .[];
    if content_length_str {
        content_length := string_to_int(content_length_str.*, T = u16);

        _, body = read_exact(*reader, xx content_length);
        body_str := to_string(body.data, body.count);
    }

    return success = true, req = .{
        method  = parse_http_method(string.{method_i, status_line.data}),
        path    = string.{path_i - method_i, status_line.data + method_i + 1},
        headers = headers,
        body = body,
    };
}

http_init_res :: () -> Http_Response {
    resp := Http_Response.{ status_code = .INTERNAL_SERVER_ERROR, allocator = context.allocator };
    Hash_Table.init(*resp.headers);
    return resp;
}

http_res_add_header :: (using resp: *Http_Response, key: string, value: string) {
    Hash_Table.table_set(*resp.headers, key, value);
}

http_res_set_body :: (resp: *Http_Response, body_to_save: $T/.[[]u8, string]) {
    resp.body = NewArray(body_to_save.count, u8, initialized=false,, resp.allocator);
    memcpy(resp.body.data, body_to_save.data, body_to_save.count * size_of(u8));
    log("---- <%>", resp.body.data);

    Hash_Table.table_set(*resp.headers, "Content-Length", tprint("%", resp.body.count));
}

http_res_to_bytes :: (using resp: *Http_Response) -> []u8 {
    bytes    : [..]u8;
    new_line := "\r\n";

    http_version := "HTTP/1.1 ";
    array_add(*bytes, http_version.data, http_version.count);

    status_code_number := tprint("%", status_code.(int));
    status_code_str    := tprint(" %", status_code);
    array_add(*bytes, status_code_number.data, status_code_number.count);
    array_add(*bytes, status_code_str.data, status_code_str.count);

    array_add(*bytes, new_line.data, new_line.count);

    header_separator := ": ";
    for :Hash_Table.for_expansion value, key: headers {
        array_add(*bytes, key.data, key.count);
        array_add(*bytes, header_separator.data, header_separator.count);
        array_add(*bytes, value.data, value.count);
        array_add(*bytes, new_line.data, new_line.count);

    }

    if body.count > 0 {
        array_add(*bytes, new_line.data, new_line.count);
        array_add(*bytes, .. body);
    }
    return bytes;
}

http_resp_deinit :: (using resp: *Http_Response) {
    Hash_Table.deinit(*headers,, allocator);
    log("---- <%>", body.data);
    free(body.data,, allocator);
}

#scope_file

array_add :: (array: *[..] $T, item: *T, count: int) #no_abc {
    for 0..count - 1 array_add(array, (item + it).*);
}

Socket_Reader :: struct {
    socket_fd        : s32;
    buffer           : [..]u8;
    read_pos         : u32;
    socket_exhausted : bool = false;
    allocator        : Allocator;
}

find_index :: (bytes: []u8, delimiter: u8, start: int = 0) -> index: int, success: bool {
    for start..bytes.count - 1 {
        if bytes[it] == delimiter {
            return index = it, success = true;
        }
    }
    return -1, false;
}

socket_reader_init :: (socket_fd: s32) -> Socket_Reader {
    return .{ socket_fd = socket_fd, read_pos = 0, allocator = context.allocator };
}

socket_reader_deinit :: (reader: *Socket_Reader) {
    free(reader.buffer.data);
}

parse_http_response :: (*resp: *Http_Response, reader: *Socket_Reader) {
    _, status_line := read_until(*reader, "\n");

}

parse_http_method :: (method: string) -> Http_Method {
    if method == {
        case "GET"; #through;
        case "get";
            return .GET;
        case "POST"; #through;
        case "post";
            return .POST;
        case "PUT"; #through;
        case "put";
            return .PUT;
        case "DELETE"; #through;
        case "delete";
            return .DELETE;
        case "PATCH"; #through;
        case "patch";
            return .PATCH;
    }
    return .GET; // Default to GET if method is unknown
}

read_exact :: (using reader: *Socket_Reader, size: u16) -> success: bool, bytes: u8 {
    // if we have enough data in the read buffer, then do early return
    if buffer.count - read_pos >= size {
        bytes := array_view(reader.buffer, reader.read_pos, size);
        reader.read_pos += size;
        return success = true, bytes = bytes;
    }

    total_read_count : u16 = 0;

    while !socket_exhausted && total_read_count <= size {
        _, read_count := socket_read_exact(reader, size);
        total_read_count += read_count;

        if reader.buffer.count - reader.read_pos >= size break;
    }

    min   := ifx size < reader.buffer.count - reader.read_pos then size
             else reader.buffer.count - reader.read_pos;
    bytes := array_view(reader.buffer, read_pos, min);

    read_pos += xx min;
    return success = true, bytes = bytes;
}


read_until :: (using reader: *Socket_Reader, delimiter: u8, $max_count: u16 = 4096) -> success: bool = true, bytes: []u8 {
    return_if_delimiter_found :: #code {
        for read_pos..buffer.count - 1 {
            if buffer[it] == delimiter {
                // + 1 so we read up to the delimiter
                bytes := array_view(buffer, read_pos, (it + 1) - reader.read_pos);
                reader.read_pos = xx (it + 1);
                return success = true, bytes = bytes;
            }
        }
    }

    #insert return_if_delimiter_found;

    local_read_count : u16 = 0;
    while !socket_exhausted && local_read_count <= max_count {
        _, read_count := socket_read_exact(reader, 100);
        local_read_count += read_count;

        #insert return_if_delimiter_found;
    }
    // if we reach here, it means we didn't find the delimiter
    // so we return the bytes read so far, if any
    bytes := array_view(reader.buffer, reader.read_pos, reader.buffer.count - reader.read_pos);
    read_pos = xx reader.buffer.count;
    return success = false, bytes = bytes;
}

socket_fill_exact :: (using reader: *Socket_Reader, size: u16) -> success: bool, read_count: u16 {
    if socket_exhausted return success = false, read_count = 0;

    BUFFER_SIZE      :: 100; // this can be smaller maybe 1 so we can get close to exact but maybe doesn't matter;
    chunk_buffer     : [BUFFER_SIZE]u8;
    local_read_count : u16 = 0;

    while !socket_exhausted && local_read_count < size {
        read_count   := POSIX.read(reader.socket_fd, chunk_buffer.data, size);

        if read_count == {
            case -1;
                error := POSIX.errno();
                if error == POSIX.EINTR // @todo Need to handle EAGAIN, EWOULDBLOCK
                    socket_read_exact(reader, size); // try again???
                log_error("read failed: %", System.get_error_string(error));
                return success = false, read_count = 0;
            case 0;
                socket_exhausted = true;
            case;
                local_read_count += xx read_count;
                array_add(*buffer, .. array_view(chunk_buffer, 0, read_count));
                if read_count < size socket_exhausted = true;
        }
    }
    return success = true, read_count = local_read_count;
}

main :: () {
    http_server(8080);

    #if MULTITHREADING {
        while true  sleep_milliseconds(60_000);
    }

    #if DEBUG_MEMORY {
        report_memory_leaks();
    }
}

http_server :: (port: u16) {
    platform_main_loop(port);
}

http_server_tls :: (port: u16, certificate_file: string, privatekey_file: string) {
    platform_main_loop(port, true, certificate_file, privatekey_file);
}

setup_socket :: (port: u16) -> Socket {
    socket_fd := socket(AF_INET, .SOCK_STREAM, 0);
    if socket_fd == INVALID_SOCKET  fatal("socket");

    #if OS == .LINUX {
        options := 1;
        if setsockopt(socket_fd, SOL_SOCKET, SO_REUSEPORT, *options, size_of(type_of(options))) == -1  fatal("setsockopt");
    }

    if bind(socket_fd, INADDR_ANY, port) != 0  fatal("bind");

    if listen(socket_fd, SOMAXCONN) != 0  fatal("listen");

    set_blocking(socket_fd, #run OS == .WINDOWS);

    return socket_fd;
}

handle_request :: (client: *Client) -> handled: bool {
    message: string = ---;
    message.data = client.request.raw.data;
    message.count = client.request.raw_count;

    found, request_line, rest := split_from_left(message, "\r\n");
    if !found  return false;

    request_parts := split(request_line, " ",, temp);
    if request_parts.count != 3 {
        bad_request(client);
        return true;
    }

    if request_parts[2] != "HTTP/1.1" {
        bad_request(client);
        return true;
    }

    found, headers_string:, rest = split_from_left(rest, "\r\n\r\n");
    if !found  return false;

    content_length := 0;

    headers := split(headers_string, "\r\n",, temp);
    for headers {
        found, key, value := split_from_left(it, ":");
        if !found {
            bad_request(client);
            return true;
        }

        key = trim(key);
        value = trim(value);

        header: Header = ---;
        header.key = key;
        header.value = value;
        array_add(*client.request.headers, header);

        if equal_nocase(key, "Content-Length") {
            content_length, success := parse_int(*value);
            if !success {
                bad_request(client);
                return true;
            }
        }

        if equal_nocase(key, "Connection") && equal_nocase(value, "close") {
            client.close_after_send = true;
        }

        if equal_nocase(key, "Keep-Alive") {
            key_values := split(value, ",",, temp);

            for key_values {
                found, key, value := split_from_left(it, "=");
                if !found {
                    bad_request(client);
                    return true;
                }

                key = trim(key);
                value = trim(value);

                if equal_nocase(key, "timeout") {
                    timeout, success := parse_int(*value);
                    if !success {
                        bad_request(client);
                        return true;
                    }

                    client.keep_alive_expiration = current_time_consensus() + seconds_to_apollo(timeout);
                }

                if equal_nocase(key, "max") {
                    max, success := parse_int(*value);
                    if !success {
                        bad_request(client);
                        return true;
                    }

                    if max < 1 {
                        bad_request(client);
                        return true;
                    }

                    client.max_requests = max;
                }
            }
        }
    }

    if content_length != rest.count  return false;

    client.request.method = request_parts[0];
    client.request.url = request_parts[1];
    client.request.body = rest;

    log("% %\n", client.request.method, client.request.url);

    if client.request.url == "/" {
        send_html(client, "<html>Hello World!</html>");
    } else if client.request.url == "/hello" {
        send_html(client, "<html>Hello from Jai!</html>");
    } else {
        not_found(client);
    }

    return true;
}

bad_request :: (client: *Client) {
    client.response.status = 400;
    client.close_after_send = true;
    send_response(client);
}

not_found :: (client: *Client) {
    client.response.status = 404;
    send_response(client);
}

send_html :: (client: *Client, html: string) {
    client.response.status = 200;

    header: Header = ---;
    header.key = "Content-Type";
    header.value = "text/html";
    array_add(*client.response.headers, header);

    client.response.body = html;

    send_response(client);
}

send_response :: (client: *Client) {
    b: String_Builder;
    b.allocator = temp;

    append(*b, tprint("HTTP/1.1 %\r\n", client.response.status));

    for client.response.headers {
        append(*b, tprint("%: %\r\n", it.key, it.value));
    }

    append(*b, tprint("Content-Length: %\r\n", client.response.body.count));
    append(*b, "\r\n");

    append(*b, client.response.body);

    client.response.serialized = builder_to_string(*b);
}

reset :: (client: *Client) {
    if client.response.serialized.data != null  free(client.response.serialized.data);

    memset(*client.request, 0, size_of(type_of(client.request)));
    memset(*client.response, 0, size_of(type_of(client.response)));

    client.request.headers.allocator = temp;
    client.response.headers.allocator = temp;
}

Header :: struct {
    key:   string;
    value: string;
}

Client :: struct {
    #if OS == .WINDOWS {
        overlapped: Windows.OVERLAPPED;
        operation: enum { RECV; SEND; }
    }

    socket_fd: Socket;

    ssl: *SSL;

    request:  Request;
    response: Response;

    close_after_send: bool;

    keep_alive_expiration: Apollo_Time;
    max_requests := -1;
    requests_handled: int;
}

Request :: struct {
    url:     string; // View into `raw`.
    method:  string; // View into `raw`.
    headers: [..] Header;
    headers.allocator = temp;

    body: string; // View into `raw`.

    #if OS == .WINDOWS {
        buffer: WSABUF;
    }

    raw: [MAX_REQUEST_SIZE] u8;
    raw_count: int;
}

Response :: struct {
    status:       int;
    headers:      [..] Header;
    headers.allocator = temp;

    body: string; // Allocate with temporary storage!

    #if OS == .WINDOWS {
        buffer: WSABUF;
    }

    serialized: string; // :Free-able
    bytes_sent: int;
}

fatal :: (message: string) {
    error := get_error_value();
    error_string := get_error_string(error);

    log("% :: [%] %\n", message, error, error_string);

    exit(1);
}

// Initial keep alive time set when a connection is accepted.
ACCEPT_KEEP_ALIVE :: #run seconds_to_apollo(60);

MAX_REQUEST_SIZE :: 65536;

MULTITHREADING :: false;
DEBUG_MEMORY   :: false;

#add_context clients: [..] Client;

// TODO: I want to be able to build and run the server without linking with libssl.
#add_context tls: bool;

#import "Basic" () (MEMORY_DEBUGGER = DEBUG_MEMORY);
#import "Socket";
#import "String";
#import "System";
#import "Thread";

#if OS == .LINUX {
    #import "Linux";
    #import "POSIX";

    #load "openssl.jai";
    #load "linux.jai";
} else #if OS == .WINDOWS {
    // We don't have TLS on Windows yet...

    SSL :: struct {};

    Windows :: #import "Windows";

    #load "windows.jai";
} else {
    assert(false, "Only Linux is supported");
}
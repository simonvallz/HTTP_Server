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
    #if !MULTITHREADING {
        thread: Thread;

        arguments: Worker_Arguments;
        arguments.port = port;

        thread.data = *arguments;

        worker(*thread);
    } else {
        num_cpus := get_number_of_processors() / 2;
        num_threads := max(num_cpus, 1);

        threads := NewArray(num_threads, Thread);

        arguments := New(Worker_Arguments);
        arguments.port = port;

        log("Starting % worker threads.\n", num_threads);

        for 0..num_threads - 1 {
            thread := *threads[it];
            thread.data = arguments;
            thread_init(thread, worker);
            thread_start(thread);
        }
    }
}

http_server_tls :: (port: u16, certificate_file: string, privatekey_file: string) {
    #if !MULTITHREADING {
        thread: Thread;

        arguments: Worker_Arguments;
        arguments.port = port;
        arguments.tls = true;
        arguments.certificate_file = certificate_file;
        arguments.privatekey_file = privatekey_file;

        thread.data = *arguments;

        worker(*thread);
    } else {
        num_cpus := get_number_of_processors() / 2;
        num_threads := max(num_cpus, 1);

        threads := NewArray(num_threads, Thread);

        arguments := New(Worker_Arguments);
        arguments.port = port;
        arguments.tls = true;
        arguments.certificate_file = certificate_file;
        arguments.privatekey_file = privatekey_file;

        log("Starting % worker threads.\n", num_threads);

        for 0..num_threads - 1 {
            thread := *threads[it];
            thread.data = arguments;

            thread_init(thread, worker);
            thread_start(thread);
        }
    }
}

Worker_Arguments :: struct {
    port: u16;
    tls: bool;
    certificate_file: string;
    privatekey_file: string;
}

worker :: (thread: *Thread) -> s64 {
    arguments := cast(*Worker_Arguments) thread.data;

    context.is_tls = arguments.tls;

    socket_fd := socket(AF_INET, .SOCK_STREAM, 0);
    if socket_fd == INVALID_SOCKET {
        perror("socket");
        exit(1);
    }

    options :=  1;
    if setsockopt(socket_fd, SOL_SOCKET, SO_REUSEPORT, *options, size_of(type_of(options))) == -1 {
        perror("setsockopt");
        exit(1);
    }

    if bind(socket_fd, INADDR_ANY, arguments.port) != 0 {
        perror("bind");
        exit(1);
    }

    if listen(socket_fd, SOMAXCONN) != 0 {
        perror("listen");
        exit(1);
    }

    set_blocking(socket_fd, false);

    if context.is_tls {
        context.ssl_ctx = create_context();
        configure_context(context.ssl_ctx, arguments.certificate_file, arguments.privatekey_file);
    }

    platform_main_loop(socket_fd);

    if context.is_tls {
        SSL_CTX_free(context.ssl_ctx);
    }

    return 0;
}

accept_clients :: (socket_fd: Socket) {
    while true {
        client_socket_fd := accept(socket_fd);
        if client_socket_fd == -1 {
            error := get_last_socket_error();
            if error == SOCKET_WOULDBLOCK  break;

            log("Error: [%] when accepting a client.\n", get_error_string(error));

            continue;
        }

        set_blocking(client_socket_fd, false);

        client := add_client(client_socket_fd);
        client.keep_alive_expiration = current_time_consensus() + ACCEPT_KEEP_ALIVE;

        if context.is_tls {
            ssl := SSL_new(context.ssl_ctx);
            SSL_set_fd(ssl, client_socket_fd);

            result := SSL_accept(ssl);

            if result <= 0 {
                error := SSL_get_error(ssl, result);
                if error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE {
                    perror("SSL_accept");
                    exit(1);
                }
            }

            client.ssl = ssl;
        }

        platform_init_ready_for_read(client_socket_fd);
    }
}

tls_read :: (client: *Client, buffer: *u8, buffer_size: u64) -> s64 {
    if context.is_tls {
        return SSL_read(client.ssl, buffer, xx buffer_size);
    } else {
        return read(client.socket_fd, buffer, buffer_size);
    }
}

read_from_client :: (socket_fd: Socket) {
    client := find_client(socket_fd);
    assert(client != null);

    while true {
        offset := client.request.raw.data + client.request.raw_count;
        max    := client.request.raw.count - client.request.raw_count;

        bytes_read := tls_read(client, offset, xx max);
        if bytes_read == -1 {
            error := get_last_socket_error();
            if error == SOCKET_WOULDBLOCK break;

            log("Error: [%] when reading from a client.\n", get_error_string(error));
            close_client(client);

            break;
        }

        if bytes_read == 0 {
            close_client(client);
            break;
        }

        client.request.raw_count += bytes_read;

        handled := handle_request(client);
        if handled {
            client.requests_handled += 1;
            if client.max_requests != -1 && client.max_requests == client.requests_handled  client.close_after_send = true;

            platform_ready_for_write(socket_fd);

            break;
        }

        if client.request.raw_count == MAX_REQUEST_SIZE {
            log("Error: client sent to much data.\n");
            close_client(client);
            break;
        }
    }
}

tls_write :: (client: *Client, buffer: *u8, buffer_size: u64) -> s64 {
    if context.is_tls {
        return SSL_write(client.ssl, buffer, xx buffer_size);
    } else {
        return write(client.socket_fd, buffer, buffer_size);
    }
}

write_to_client :: (socket_fd: Socket) {
    client := find_client(socket_fd);
    assert(client != null);

    if client.response.serialized.count - client.response.bytes_sent == 0 {
        if client.close_after_send {
            close_client(client);
            return;
        }
    }

    while client.response.serialized.count - client.response.bytes_sent > 0 {
        offset := client.response.serialized.data + client.response.bytes_sent;
        max    := client.response.serialized.count - client.response.bytes_sent;

        bytes_sent := tls_write(client, offset, xx max);
        if bytes_sent == -1 {
            error := get_last_socket_error();
            if error == SOCKET_WOULDBLOCK  break;

            log("Error: [%] when sending to a client.\n", get_error_string(error));
            close_client(client);

            break;
        }

        client.response.bytes_sent += bytes_sent;
    }

    if client.response.serialized.count - client.response.bytes_sent == 0 {
        reset(client);
        if !client.close_after_send  platform_ready_for_read(socket_fd);
    }
}

close_client :: (client: *Client) {
    socket_fd := client.socket_fd;

    reset(client);
    remove_client(client);
    close_and_reset(*socket_fd);
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

process_keep_alive :: () {
    now := current_time_consensus();

    for * context.clients {
        if it.keep_alive_expiration < now  close_client(it);
    }
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

create_sigint_fd :: () -> s32 {
    mask: sigset_t;
    sigemptyset(*mask);
    sigaddset(*mask, SIGINT);

    if sigprocmask(SIG_BLOCK, *mask, null) == -1 {
        perror("sigprocmask");
        exit(1);
    }

    sigint_fd := signalfd(-1, *mask, 0);
    if sigint_fd == -1 {
        perror("signalfd");
        exit(1);
    }

    return sigint_fd;
}

add_client :: (socket_fd: Socket) -> *Client {
    client := array_add(*context.clients);
    client.socket_fd = socket_fd;
    return client;
}

find_client :: (socket_fd: Socket) -> *Client {
    for * context.clients {
        if it.socket_fd == socket_fd  return it;
    }

    return null;
}

reset :: (client: *Client) {
    if client.response.serialized.data != null  free(client.response.serialized.data);

    memset(*client.request, 0, size_of(type_of(client.request)));
    memset(*client.response, 0, size_of(type_of(client.response)));

    client.request.headers.allocator = temp;
    client.response.headers.allocator = temp;
}

remove_client :: (client: *Client) {
    for context.clients {
        if it.socket_fd == client.socket_fd  remove it;
    }
}

Header :: struct {
    key:   string;
    value: string;
}

Client :: struct {
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

    raw: [MAX_REQUEST_SIZE] u8;
    raw_count: int;
}

Response :: struct {
    status:       int;
    headers:      [..] Header;
    headers.allocator = temp;

    body: string; // Allocate with temporary storage!

    serialized: string; // :Free-able
    bytes_sent: int;
}

// Initial keep alive time set when a connection is accepted.
ACCEPT_KEEP_ALIVE :: #run seconds_to_apollo(60);

MAX_REQUEST_SIZE :: 65536;

MULTITHREADING :: false;
DEBUG_MEMORY   :: false;

#add_context clients: [..] Client;
#add_context ssl_ctx: *SSL_CTX;
#add_context is_tls: bool;

#import "Basic" () (MEMORY_DEBUGGER = DEBUG_MEMORY);
#import "Socket";
#import "String";
#import "System";
#import "Thread";

#load "openssl.jai";

#if OS == .LINUX {
    #import "Linux";
    #import "POSIX";

    #load "platform/linux.jai";
} else {
    assert(false, "Only Linux is supported");
}
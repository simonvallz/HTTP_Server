main :: () {
    http_server();

    #if MULTITHREADING {
        while true  sleep_milliseconds(60_000);
    }

    #if DEBUG_MEMORY {
        report_memory_leaks();
    }
}

http_server :: () {
    #if !MULTITHREADING {
        thread: Thread;
        worker(*thread);
    } else {
        num_cpus := get_number_of_processors() / 2;
        num_threads := max(num_cpus, 1);
        threads := NewArray(num_threads, Thread);

        log("Starting % worker threads.\n", num_threads);

        for 0..num_threads - 1 {
            thread := *threads[it];
            thread_init(thread, worker);
            thread_start(thread);
        }
    }
}

worker :: (thread: *Thread) -> s64 {
    signal(SIGPIPE, SIG_IGN);

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

    if bind(socket_fd, INADDR_ANY, 8080) != 0 {
        perror("bind");
        exit(1);
    }

    if listen(socket_fd, SOMAXCONN) != 0 {
        perror("listen");
        exit(1);
    }

    set_blocking(socket_fd, false);

    context.epoll_fd = epoll_create1(0);
    if context.epoll_fd == -1  {
        perror("epoll_create");
        exit(1);
    }

    epoll_add(EPOLLIN | EPOLLET, socket_fd);

    #if !MULTITHREADING {
        sigint_fd := create_sigint_fd();
        epoll_add(EPOLLIN | EPOLLET, sigint_fd);
    }

    events: [1024] epoll_event;
    quit := false;

    while !quit {
        nfds := epoll_wait(context.epoll_fd, events.data, events.count, -1);
        if nfds == -1 {
            perror("epoll_wait");
            exit(1);
        }

        for 0..nfds - 1 {
            ev := events[it];

            #if !MULTITHREADING {
                if ev.data.fd == sigint_fd {
                    quit = true;
                    break;
                }
            }

            if ev.data.fd == socket_fd {
                accept_clients(socket_fd);
            } else if ev.events & EPOLLIN {
                read_from_client(ev.data.fd);
            } else if ev.events & EPOLLOUT {
                write_to_client(ev.data.fd);
            }
        }

        process_keep_alive();

        reset_temporary_storage();
    }

    return 0;
}

accept_clients :: (socket_fd: Socket) {
    while true {
        client_socket_fd := accept(socket_fd);
        if client_socket_fd == -1 {
            error := get_last_socket_error();
            if error == EAGAIN || error == EWOULDBLOCK  break;

            log("Error: [%] when accepting a client.\n", get_error_string(error));

            continue;
        }

        set_blocking(client_socket_fd, false);

        client := add_client(client_socket_fd);
        client.keep_alive_expiration = current_time_consensus() + ACCEPT_KEEP_ALIVE;

        epoll_add(EPOLLIN | EPOLLET, client_socket_fd);
    }
}

read_from_client :: (socket_fd: Socket) {
    client := find_client(socket_fd);
    assert(client != null);

    while true {
        offset := client.request.raw.data + client.request.raw_count;
        max    := client.request.raw.count - client.request.raw_count;

        bytes_read := recv(socket_fd, offset, xx max, 0);
        if bytes_read == -1 {
            error := get_last_socket_error();
            if error == EAGAIN || error == EWOULDBLOCK break;

            log("Error: [%] when reading from a client.\n", get_error_string(error));
            close_client(socket_fd);

            break;
        }

        if bytes_read == 0 {
            close_client(socket_fd);
            break;
        }

        client.request.raw_count += bytes_read;

        handled := handle_request(client);
        if handled {
            client.requests_handled += 1;
            if client.max_requests != -1 && client.max_requests == client.requests_handled  client.close_after_send = true;

            epoll_mod(EPOLLOUT | EPOLLET, socket_fd);

            break;
        }

        if client.request.raw_count == MAX_REQUEST_SIZE {
            log("Error: client sent to much data.\n");
            close_client(socket_fd);
            break;
        }
    }
}

write_to_client :: (socket_fd: Socket) {
    client := find_client(socket_fd);
    assert(client != null);

    if client.response.serialized.count - client.response.bytes_sent == 0 {
        if client.close_after_send {
            close_client(socket_fd);
            return;
        }
    }

    while client.response.serialized.count - client.response.bytes_sent > 0 {
        offset := client.response.serialized.data + client.response.bytes_sent;
        max    := client.response.serialized.count - client.response.bytes_sent;

        bytes_sent := send(socket_fd, offset, xx max, 0);
        if bytes_sent == -1 {
            error := get_last_socket_error();
            if error == EAGAIN || error == EWOULDBLOCK  break;

            log("Error: [%] when sending to a client.\n", get_error_string(error));
            close_client(socket_fd);

            break;
        }

        client.response.bytes_sent += bytes_sent;
    }

    if client.response.serialized.count - client.response.bytes_sent == 0 {
        reset(socket_fd);
        if !client.close_after_send  epoll_mod(EPOLLIN | EPOLLET, socket_fd);
    }
}

close_client :: (socket_fd: Socket) {
    reset(socket_fd);
    remove_client(socket_fd);
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

    for context.clients {
        if it.keep_alive_expiration < now  close_client(it.socket_fd);
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
    client.response.content_type = "text/html";
    client.response.body = html;
    send_response(client);
}

send_response :: (client: *Client) {
    b: String_Builder;
    b.allocator = temp;

    append(*b, tprint("HTTP/1.1 %\r\n", client.response.status));

    if client.response.content_type.count > 0  append(*b, tprint("Content-Type: %\r\n", client.response.content_type));

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

epoll_add :: (events: u32, fd: s32) {
    ev: epoll_event;
    ev.events = events;
    ev.data.fd = fd;

    if epoll_ctl(context.epoll_fd, .ADD, fd, *ev) == -1 {
        perror("epoll_ctl");
        exit(1);
    }
}

epoll_mod :: (events: u32,  fd: s32) {
    ev: epoll_event;
    ev.events = events;
    ev.data.fd = fd;

    if epoll_ctl(context.epoll_fd, .MOD, fd, *ev) == -1 {
        perror("epoll_ctl");
        exit(1);
    }
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

reset :: (socket_fd: Socket) {
    for * context.clients {
        if it.socket_fd == socket_fd {
            if it.request.headers.data != null      free(it.request.headers.data);
            if it.response.headers.data != null     free(it.response.headers.data);
            if it.response.serialized.data != null  free(it.response.serialized.data);

            memset(*it.request, 0, size_of(type_of(it.request)));
            memset(*it.response, 0, size_of(type_of(it.response)));

            break;
        }
    }
}

remove_client :: (socket_fd: Socket) {
    for context.clients {
        if it.socket_fd == socket_fd  remove it;
    }
}

Header :: struct {
    key:   string;
    value: string;
}

Client :: struct {
    socket_fd: Socket;

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

    body: string; // View into `raw`.

    raw: [MAX_REQUEST_SIZE] u8;
    raw_count: int;
}

Response :: struct {
    status:       int;
    content_type: string; // Allocate with temporary storage!
    headers:      [..] Header;

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
#add_context epoll_fd: s32;

#import "Basic" () (MEMORY_DEBUGGER = DEBUG_MEMORY);
#import "Linux";
#import "POSIX";
#import "Socket";
#import "String";
#import "System";
#import "Thread";

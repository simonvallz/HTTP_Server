main :: () {
    http_server();
}

http_server :: () {
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

    epoll_fd := epoll_create1(0);
    if epoll_fd == -1  {
        perror("epoll_create");
        exit(1);
    }

    epoll_add(epoll_fd, EPOLLIN | EPOLLET, socket_fd);

    events: [1024] epoll_event;
    while true {
        nfds := epoll_wait(epoll_fd, events.data, events.count, -1);
        if nfds == -1 {
            perror("epoll_wait");
            exit(1);
        }

        for 0..nfds - 1 {
            ev := events[it];

            if ev.data.fd == socket_fd {
                accept_clients(epoll_fd, socket_fd);
            } else if ev.events & EPOLLIN {
                read_from_client(epoll_fd, ev.data.fd);
            } else if ev.events & EPOLLOUT {
                write_to_client(epoll_fd, ev.data.fd);
            }
        }

        reset_temporary_storage();
    }
}

accept_clients :: (epoll_fd: s32, socket_fd: Socket) {
    while true {
        client_socket_fd := accept(socket_fd);
        if client_socket_fd == -1 {
            error := get_last_socket_error();
            if error == EAGAIN || error == EWOULDBLOCK  break;

            log("Error: [%] when accepting a client.\n", get_error_string(error));

            continue;
        }

        set_blocking(client_socket_fd, false);
        add_client(client_socket_fd);
        epoll_add(epoll_fd, EPOLLIN | EPOLLET, client_socket_fd);
    }
}

read_from_client :: (epoll_fd: s32, socket_fd: Socket) {
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
            epoll_mod(epoll_fd, EPOLLOUT | EPOLLET, socket_fd);
            break;
        }

        if client.request.raw_count == MAX_REQUEST_SIZE {
            log("Error: client sent to much data.\n");
            close_client(socket_fd);
            break;
        }
    }
}

write_to_client :: (epoll_fd: s32, socket_fd: Socket) {
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
        if !client.close_after_send  epoll_mod(epoll_fd, EPOLLIN | EPOLLET, socket_fd);
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

        if equal_nocase(key, "Content-Length") {
            success: bool;
            content_length, success = parse_int(*trim(value));
            if !success {
                bad_request(client);
                return true;
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
    client.response.content_type = copy_string("text/html");
    client.response.body = copy_string(html);
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

epoll_add :: (epoll_fd: s32, events: u32, fd: s32) {
    ev: epoll_event;
    ev.events = events;
    ev.data.fd = fd;

    if epoll_ctl(epoll_fd, .ADD, fd, *ev) == -1 {
        perror("epoll_ctl");
        exit(1);
    }
}

epoll_mod :: (epoll_fd: s32, events: u32,  fd: s32) {
    ev: epoll_event;
    ev.events = events;
    ev.data.fd = fd;

    if epoll_ctl(epoll_fd, .MOD, fd, *ev) == -1 {
        perror("epoll_ctl");
        exit(1);
    }
}

add_client :: (socket_fd: Socket) -> *Client {
    client := array_add(*clients);
    client.socket_fd = socket_fd;
    return client;
}

find_client :: (socket_fd: Socket) -> *Client {
    for * clients {
        if it.socket_fd == socket_fd  return it;
    }

    return null;
}

reset :: (socket_fd: Socket) {
    for * clients {
        if it.socket_fd == socket_fd {
            it.request.raw_count = 0;
            it.response.bytes_sent = 0;

            if it.response.content_type.data != null {
                free(it.response.content_type.data);
                it.response.content_type.data = null;
                it.response.content_type.count = 0;
            }

            if it.response.body.data != null {
                free(it.response.body.data);
                it.response.body.data = null;
                it.response.body.count = 0;
            }

            if it.response.serialized.data != null {
                free(it.response.serialized.data);
                it.response.serialized.data = null;
                it.response.serialized.count = 0;
            }

            break;
        }
    }
}

remove_client :: (socket_fd: Socket) {
    for clients {
        if it.socket_fd == socket_fd  remove it;
    }
}

clients: [..] Client;

Client :: struct {
    socket_fd: Socket;

    request:  Request;
    response: Response;

    close_after_send: bool;
}

Request :: struct {
    url:    string; // View into `raw`.
    method: string; // View into `raw`.

    body: string; // View into `raw`.

    raw: [MAX_REQUEST_SIZE] u8;
    raw_count: int;
}

Response :: struct {
    status:       int;
    content_type: string; // :Free-able

    body: string; // :Free-able

    serialized: string; // :Free-able
    bytes_sent: int;
}

MAX_REQUEST_SIZE :: 65536;

#import "Basic";
#import "Linux";
#import "POSIX";
#import "Socket";
#import "String";
#import "System";

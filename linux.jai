#scope_module

platform_main_loop :: (port: u16, tls := false, certificate_file := "", private_key_file := "", request_handler: Request_Handler) {
    socket_init();

    POSIX.signal(POSIX.SIGPIPE, POSIX.SIG_IGN);

    arguments := New(Worker_Arguments);
    arguments.port = port;
    arguments.tls = tls;
    arguments.certificate_file = certificate_file;
    arguments.private_key_file = private_key_file;
    arguments.request_handler = request_handler;

    num_cpus := get_number_of_processors() / 2;
    num_threads := max(num_cpus - 1, 1);

    threads := NewArray(num_threads, Thread);

    for 0..num_threads - 1 {
        thread := *threads[it];
        thread.data = arguments;

        thread_init(thread, worker);
        thread_start(thread);
    }

    main_thread: Thread;
    main_thread.data = arguments;
    worker(*main_thread);
}

Worker_Arguments :: struct {
    port: u16;

    tls:              bool;
    certificate_file: string;
    private_key_file: string;

    request_handler: Request_Handler;
}

worker :: (thread: *Thread) -> s64 {
    arguments := cast(*Worker_Arguments) thread.data;

    socket_fd := setup_socket(arguments.port);

    #if TLS {
        if arguments.tls {
            context.tls = true;
            context.ssl_ctx = create_context();
            configure_context(context.ssl_ctx, arguments.certificate_file, arguments.private_key_file);
        }
    }

    context.epoll_fd = Linux.epoll_create1(0);
    if context.epoll_fd == -1 {
        fatal("epoll_create");
    }

    epoll_add(Linux.EPOLLIN | Linux.EPOLLET, socket_fd);

    events: [1024] Linux.epoll_event;
    quit := false;

    while !quit {
        nfds := Linux.epoll_wait(context.epoll_fd, events.data, events.count, -1);
        if nfds == -1 {
            fatal("epoll_wait");
        }

        for 0..nfds - 1 {
            ev := events[it];

            if ev.data.fd == socket_fd {
                accept_clients(socket_fd);
            } else if ev.events & Linux.EPOLLIN {
                read_from_client(ev.data.fd, arguments.request_handler);
            } else if ev.events & Linux.EPOLLOUT {
                write_to_client(ev.data.fd);
            }
        }

        process_keep_alive();

        reset_temporary_storage();
    }

    #if TLS {
        if context.tls {
            SSL_CTX_free(context.ssl_ctx);
        }
    }

    return 0;
}

accept_clients :: (socket_fd: Socket) {
    while true {
        client_socket_fd := accept(socket_fd);
        if client_socket_fd == INVALID_SOCKET {
            error := get_last_socket_error();
            if error == SOCKET_WOULDBLOCK  break;

            log("Error: [%] when accepting a client.\n", get_error_string(error));

            continue;
        }

        set_blocking(client_socket_fd, false);

        client := add_client(client_socket_fd);
        client.keep_alive_expiration = current_time_monotonic() + ACCEPT_KEEP_ALIVE;

        #if TLS {
            if context.tls {
                ssl := SSL_new(context.ssl_ctx);
                SSL_set_fd(ssl, xx client_socket_fd);

                result := SSL_accept(ssl);

                if result <= 0 {
                    error := SSL_get_error(ssl, result);
                    if error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE  fatal("SSL_accept");
                }

                client.ssl = ssl;
            }
        }

        epoll_add(Linux.EPOLLIN | Linux.EPOLLET, client_socket_fd);
    }
}

tls_read :: (client: *Client, buffer: *u8, buffer_size: u64) -> s64 {
    #if TLS {
        if context.tls {
            return SSL_read(client.ssl, buffer, xx buffer_size);
        } else {
            return recv(client.socket_fd, buffer, xx buffer_size, 0);
        }
    } else {
        return recv(client.socket_fd, buffer, xx buffer_size, 0);
    }
}

read_from_client :: (socket_fd: Socket, request_handler: Request_Handler) {
    client := find_client(socket_fd);
    assert(client != null);

    while true {
        client.keep_alive_expiration = current_time_monotonic() + KEEP_ALIVE;

        offset := client.request.raw.data + client.request.raw_count;
        max    := client.request.raw.count - client.request.raw_count;

        bytes_read := tls_read(client, offset, xx max);
        if bytes_read == -1 {
            error := get_last_socket_error();
            if error == SOCKET_WOULDBLOCK  break;

            log("Error: [%] when reading from a client.\n", get_error_string(error));
            close_client(client);

            break;
        }

        if bytes_read == 0 {
            close_client(client);
            break;
        }

        client.request.raw_count += bytes_read;

        handled := handle_request(client, request_handler);
        if handled {
            epoll_mod(Linux.EPOLLOUT | Linux.EPOLLET, socket_fd);
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
    #if TLS {
        if context.tls {
            return SSL_write(client.ssl, buffer, xx buffer_size);
        } else {
            return send(client.socket_fd, buffer, xx buffer_size, 0);
        }
    } else {
        return send(client.socket_fd, buffer, xx buffer_size, 0);
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
        client.keep_alive_expiration = current_time_monotonic() + KEEP_ALIVE;

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
        if !client.close_after_send  epoll_mod(Linux.EPOLLIN | Linux.EPOLLET, socket_fd);
    }
}

epoll_add :: (events: u32, fd: s32) {
    ev: Linux.epoll_event;
    ev.events = events;
    ev.data.fd = fd;

    if Linux.epoll_ctl(context.epoll_fd, .ADD, fd, *ev) == -1 {
        fatal("epoll_ctl");
    }
}

epoll_mod :: (events: u32,  fd: s32) {
    ev: Linux.epoll_event;
    ev.events = events;
    ev.data.fd = fd;

    if Linux.epoll_ctl(context.epoll_fd, .MOD, fd, *ev) == -1 {
        fatal("epoll_ctl");
    }
}

close_client :: (client: *Client) {
    socket_fd := client.socket_fd;

    #if TLS {
        if context.tls {
            SSL_shutdown(client.ssl);
            SSL_free(client.ssl);
        }
    }

    reset(client);
    remove_client(client);
    close_and_reset(*socket_fd);
}

process_keep_alive :: () {
    now := current_time_monotonic();

    for * context.clients {
        if it.keep_alive_expiration < now  close_client(it);
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

remove_client :: (client: *Client) {
    socket_fd := client.socket_fd;

    for context.clients {
        if it.socket_fd == socket_fd  remove it;
    }
}

#add_context epoll_fd: s32;
#add_context clients: [..] Client;
#add_context tls: bool;
#add_context ssl_ctx: *SSL_CTX;

Linux :: #import "Linux";
POSIX :: #import "POSIX";

#if TLS {
    #load "openssl.jai";
} else {
    SSL_CTX :: struct {};
}
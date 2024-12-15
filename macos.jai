#scope_module

platform_main_loop :: (port: u16, tls := false, certificate_file := "", private_key_file := "",  request_handler: Request_Handler) {
    assert(!tls); // TLS not supported on macOS yet.

    socket_init();

    // Why doesn't this work?
    //POSIX.signal(POSIX.SIGPIPE, POSIX.SIG_IGN);

    num_cpus := get_number_of_processors();
    num_threads := max(num_cpus - 1, 1);

    arguments := New(Worker_Arguments);
    arguments.port = port;
    arguments.request_handler = request_handler;

    log("Starting % worker threads.\n", num_threads);

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
    request_handler: Request_Handler;
}

worker :: (thread: *Thread) -> s64 {
    arguments := cast(*Worker_Arguments) thread.data;

    socket_fd := setup_socket(arguments.port);

    kq := Macos.kqueue();
    if kq == -1  fatal("kqueue");

    kqueue_add(.READ, socket_fd);

    event_list: [1024] Macos.Kevent64;

    while true {
        nfds := Macos.kevent64(kq, context.kqueue_change_list.data, xx context.kqueue_change_list.count, event_list.data, xx event_list.count, .KEVENT_FLAG_NONE, null);
        if nfds == -1  fatal("epoll_wait");

        array_reset_keeping_memory(*context.kqueue_change_list);

        for i: 0..nfds - 1 {
            ev := event_list[i];

            if ev.flags & .EOF  continue;

            if ev.ident == xx socket_fd {
                accept_clients(socket_fd);
            } else if ev.filter == .READ {
                read_from_client(xx ev.ident, arguments.request_handler);
            } else if ev.filter == .WRITE {
                write_to_client(xx ev.ident);
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
        if client_socket_fd == INVALID_SOCKET {
            error := get_last_socket_error();
            if error == SOCKET_WOULDBLOCK  break;

            log("Error: [%] when accepting a client.\n", get_error_string(error));

            continue;
        }

        set_blocking(client_socket_fd, false);

        client := add_client(client_socket_fd);
        client.keep_alive_expiration = current_time_monotonic() + ACCEPT_KEEP_ALIVE;

        kqueue_add(.READ, client_socket_fd);
    }
}

read_from_client :: (socket_fd: Socket, request_handler: Request_Handler) {
    client := find_client(socket_fd);
    assert(client != null);

    while true {
        client.keep_alive_expiration = current_time_monotonic() + KEEP_ALIVE;

        offset := client.request.raw.data + client.request.raw_count;
        max    := client.request.raw.count - client.request.raw_count;

        bytes_read := recv(client.socket_fd, offset, xx max, 0);
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

        handled := handle_request(client, request_handler);
        if handled {
            kqueue_mod(.WRITE, socket_fd);
            break;
        }

        if client.request.raw_count == MAX_REQUEST_SIZE {
            log("Error: client sent to much data.\n");
            close_client(client);
            break;
        }
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

        bytes_sent := send(client.socket_fd, offset, xx max, 0);
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
        if !client.close_after_send  kqueue_mod(.READ, socket_fd);
    }
}

kqueue_add :: (filter: Macos.Kevent_Filter, fd: s32) {
    event: Macos.Kevent64;
    event.ident = xx fd;
    event.filter = filter;
    event.flags = .ADD | .ENABLE;

    array_add(*context.kqueue_change_list, event);
}

kqueue_mod :: (filter: Macos.Kevent_Filter, fd: s32) {
    kqueue_delete(fd);

    event: Macos.Kevent64;
    event.ident = xx fd;
    event.filter = filter;
    event.flags = .ADD | .ENABLE;

    array_add(*context.kqueue_change_list, event);
}

kqueue_delete :: (fd: s32) {
    event: Macos.Kevent64;
    event.ident = xx fd;
    event.flags = .DELETE;

    array_add(*context.kqueue_change_list, event);
}

close_client :: (client: *Client) {
    socket_fd := client.socket_fd;

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

#add_context kqueue_change_list: [..] Macos.Kevent64;
#add_context clients: [..] Client;

Macos :: #import "macos";
POSIX :: #import "POSIX";
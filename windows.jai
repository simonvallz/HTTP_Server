#scope_module

platform_main_loop :: (port: u16, tls := false, certificate_file := "", private_key_file := "", request_handler: Request_Handler) {
    assert(!tls); // TLS not supported on Windows yet.

    init(*clients_lock);

    socket_init();

    socket_fd := setup_socket(port);

    completion_port = Windows.CreateIoCompletionPort(Windows.INVALID_HANDLE_VALUE, null, 0, 1);
    if completion_port == null {
        fatal("CreateIoCompletionPort");
    }

    num_cpus := get_number_of_processors() / 2;
    num_threads := max(num_cpus, 1);
    threads := NewArray(num_threads, Thread);
    defer free(threads.data);

    for * threads {
        it.data = xx request_handler;

        thread_init(it, iocp_worker);
        thread_start(it);
    }

    while true {
        client_socket_fd := accept(socket_fd);
        if client_socket_fd == INVALID_SOCKET  fatal("accept");

        lock(*clients_lock);
        client, locator := find_and_occupy_empty_slot(*clients);
        unlock(*clients_lock);

        client.locator = locator;
        client.socket_fd = client_socket_fd;
        client.keep_alive_expiration = current_time_monotonic() + ACCEPT_KEEP_ALIVE;
        client.request.buffer.buf = client.request.raw.data;
        client.request.buffer.len = client.request.raw.count;

        set_blocking(client_socket_fd, false);

        Windows.CreateIoCompletionPort(xx client_socket_fd, completion_port, client_socket_fd, 0);

        read_from_client(client);

        process_keep_alive();

        reset_temporary_storage();
    }

    Windows.CloseHandle(completion_port);
}

iocp_worker :: (thread: *Thread) -> s64 {
    request_handler := cast(Request_Handler) thread.data;

    while true {
        bytes_transfered: Windows.DWORD;
        client_socket_fd: Socket;
        overlapped: *Windows.OVERLAPPED;

        success := Windows.GetQueuedCompletionStatus(completion_port, *bytes_transfered, *client_socket_fd, *overlapped, Windows.INFINITE);

        client := cast(*Client) overlapped;

        if !success || bytes_transfered == 0 {
            if client {
                client.shutdown = true;
                ref_decrement(client);
            }

            continue;
        }

        if #complete client.operation == {
            case .RECV;
                client.request.raw_count += bytes_transfered;

                handled := handle_request(client, request_handler);
                if !handled {
                    read_from_client(client);
                    continue;
                }

                client.operation = .SEND;
                client.response.buffer.buf = client.response.serialized.data;
                client.response.buffer.len = xx client.response.serialized.count;

                write_to_client(client);
            case .SEND;
                reset(client);
                client.operation = .RECV;

                client.request.buffer.buf = client.request.raw.data;
                client.request.buffer.len = client.request.raw.count;

                read_from_client(client);
        }

        client.keep_alive_expiration = current_time_monotonic() + KEEP_ALIVE;

        ref_decrement(client);

        reset_temporary_storage();
    }

    return 0;
}

read_from_client :: (client: *Client) {
    if client.shutdown  return;

    ref_increment(client);

    flags: u32;
    result := WSARecv(client.socket_fd, *client.request.buffer, 1, null, *flags, *client.overlapped, null);
    if result == SOCKET_ERROR {
        error := get_last_socket_error();
        if error == Windows.ERROR_IO_PENDING  return;

        ref_decrement(client);
    }
}

write_to_client :: (client: *Client) {
    if client.shutdown  return;

    ref_increment(client);

    flags: u32;
    send_result := WSASend(client.socket_fd, *client.response.buffer, 1, null, flags, *client.overlapped, null);
    if send_result == SOCKET_ERROR {
        error := get_last_socket_error();
        if error == Windows.ERROR_IO_PENDING  return;

        ref_decrement(client);
    }
}

process_keep_alive :: () {
    now := current_time_monotonic();

    lock(*clients_lock);
    for * clients {
        if it.keep_alive_expiration < now {
            it.shutdown = true;
            ref_decrement(it, false);
        }
    }
    unlock(*clients_lock);
}

ref_increment :: (client: *Client) {
    atomic_increment(*client.ref_count);
}

ref_decrement :: (client: *Client, $lock_mutex := true) {
    atomic_decrement(*client.ref_count);
    if client.ref_count == 0 {
        closesocket(client.socket_fd);

        #if lock_mutex  lock(*clients_lock);
        bucket_array_remove(*clients, client.locator);
        #if lock_mutex  unlock(*clients_lock);
    }
}

clients_lock: Mutex;
clients: Bucket_Array(Client, 64);

completion_port: Windows.HANDLE;

#import "Atomics";
#import "Bucket_Array";

Windows :: #import "Windows";
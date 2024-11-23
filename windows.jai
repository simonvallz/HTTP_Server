// TODO:
// - TLS support.
// - Multithreading
// - Gracefull shutdown with Ctrl-C when not multithreading.

platform_main_loop :: (port: u16, tls := false, certificate_file := "", privatekey_file := "") {
    assert(!tls, "TLS is not supported on Windows yet.");
    #assert(!MULTITHREADING);

    socket_init();

    socket_fd := setup_socket(port);

    completion_port = Windows.CreateIoCompletionPort(Windows.INVALID_HANDLE_VALUE, null, 0, 1);
    if completion_port == null {
        fatal("CreateIoCompletionPort");
    }

    thread: Thread;
    thread_init(*thread, iocp_worker);
    thread_start(*thread);

    quit := false;

    while !quit {
        client_socket_fd := accept(socket_fd);
        if client_socket_fd == INVALID_SOCKET {
            fatal("accept");
        }

        client := New(Client);
        client.socket_fd = client_socket_fd;
        client.request.buffer.buf = client.request.raw.data;
        client.request.buffer.len = client.request.raw.count;

        Windows.CreateIoCompletionPort(xx client_socket_fd, completion_port, client_socket_fd, 0);

        error := read_from_client(client);
        if error {
            close_and_reset(*client.socket_fd);
            free(client);
            continue;
        }
    }

    Windows.CloseHandle(completion_port);
}

iocp_worker :: (thread: *Thread) -> s64 {
    while true {
        bytes_transfered: Windows.DWORD;
        client_socket_fd: Socket;
        overlapped: *Windows.OVERLAPPED;

        result := Windows.GetQueuedCompletionStatus(completion_port, *bytes_transfered, *client_socket_fd, *overlapped, Windows.INFINITE);
        if !result {
            fatal("GetQueuedCompletionStatus");
        }

        client := cast(*Client) overlapped;

        if bytes_transfered == 0 {
            close_and_reset(*client_socket_fd);
            free(client);
            continue;
        }

        if #complete client.operation == {
            case .RECV;
                client.request.raw_count += bytes_transfered;

                handled := handle_request(client);
                if !handled {
                    read_from_client(client);
                    continue;
                }

                client.operation = .SEND;
                client.response.buffer.buf = client.response.serialized.data;
                client.response.buffer.len = xx client.response.serialized.count;

                error := write_to_client(client);
                if error {
                    close_and_reset(*client.socket_fd);
                    free(client);
                    continue;
                }
            case .SEND;
                reset(client);
                client.operation = .RECV;

                client.request.buffer.buf = client.request.raw.data;
                client.request.buffer.len = client.request.raw.count;

                error := read_from_client(client);
                if error {
                    close_and_reset(*client.socket_fd);
                    free(client);
                    continue;
                }
        }
    }

    return 0;
}

read_from_client :: (client: *Client) -> error:  bool {
    flags: u32;
    result := WSARecv(client.socket_fd, *client.request.buffer, 1, null, *flags, *client.overlapped, null);
    if result == SOCKET_ERROR {
        error := get_last_socket_error();

        return error != Windows.ERROR_IO_PENDING;
    }

    return false;
}

write_to_client :: (client: *Client) -> error: bool {
    flags: u32;
    send_result := WSASend(client.socket_fd, *client.response.buffer, 1, null, flags, *client.overlapped, null);
    if send_result == SOCKET_ERROR {
        error := get_last_socket_error();

        return error != Windows.ERROR_IO_PENDING;
    }

    return false;
}

completion_port: Windows.HANDLE;
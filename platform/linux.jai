platform_main_loop :: (socket_fd: Socket) {
    signal(SIGPIPE, SIG_IGN);

    context.epoll_fd = epoll_create1(0);
    if context.epoll_fd == -1 {
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
}

platform_init_ready_for_read :: (socket_fd: Socket) {
    epoll_add(EPOLLIN | EPOLLET, socket_fd);
}

platform_ready_for_read :: (socket_fd: Socket) {
    epoll_mod(EPOLLIN | EPOLLET, socket_fd);
}

platform_ready_for_write :: (socket_fd: Socket) {
    epoll_mod(EPOLLOUT | EPOLLET, socket_fd);
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

#add_context epoll_fd: s32;
# HTTP Server for Jai

This is an HTTP server library for Jai. It works on Windows, Linux and macOS. See `examples/basic/main.jai` for a basic example of how to use it.

## Features

- Windows (IOCP), Linux (epoll) and macOS (kqueue)
- Partly implements HTTP/1.1

## TODO

- TLS on Windows and macOS
- Full HTTP/1.1
- HTTP/2
- Router (see `examples/router/main.jai`)
- Compression (brotli and gzip? Again, I would prefer something written in Jai but that might not exist.)
- Web sockets
- Don't call process_keep_alive in each iteration of the loop.

## Development tips

- Run a basic test suite with `jai tests/first.jai`.

## Performance

This seems to be about half the speed of the standard Go HTTP server. I am not sure why.

## Contributing

If you want to contribute feel free to open a pull request!
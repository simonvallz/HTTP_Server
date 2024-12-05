handle_request :: () {
    message: String_Builder;

    append(*message, "GET / HTTP/1.1\r\n");
    append(*message, "Connection: Keep-Alive\r\n");
    append(*message, "\r\n");

    http_message := builder_to_string(*message);

    client: Client;

    memcpy(client.request.raw.data, http_message.data, http_message.count);
    client.request.raw_count = http_message.count;

    handled := handle_request(*client, request_handler);
    test(handled, "handle_request handles basic request.");
} @test

request_handler :: (request: *Request, response: *Response) {}

#load "../module.jai";
handle_request :: () {
    test("handle_request handles basic requests", () {
        message: String_Builder;

        append(*message, "GET / HTTP/1.1\r\n");
        append(*message, "Connection: close\r\n");
        append(*message, "\r\n");

        http_message := builder_to_string(*message);

        client: Client;

        memcpy(client.request.raw.data, http_message.data, http_message.count);
        client.request.raw_count = http_message.count;

        handled := handle_request(*client, request_handler);
        expect(handled);
    });
} @test

request_handler :: (request: *Request, response: *Response) {}

#load "../module.jai";
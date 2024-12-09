handle_request :: () {
    test("handle_request handles basic requests", () {
        message: String_Builder;

        append(*message, "GET / HTTP/1.1\r\n");
        append(*message, "Connection: close\r\n");
        append(*message, "\r\n");

        http_message := builder_to_string(*message);

        client: Client;

        set_request_to(*client.request, http_message);

        handled := handle_request(*client, (request: *Request, response: *Response) {
            expect(request.method == "GET");
            expect(request.url == "/");
            expect(request.body == "");

            expect(request.headers.count == 1);
            expect(request.headers[0].key == "Connection");
            expect(request.headers[0].value == "close");

            html(response, "<html>Hello</html>");
        });

        expect(handled);
        expect(client.response.status == .Ok);
        expect(client.response.body == "<html>Hello</html>");
        expect(client.close_after_send == true);
    });

    test("handle_request handles request without headers", () {
        message: String_Builder;

        append(*message, "GET / HTTP/1.1\r\n");
        append(*message, "\r\n");

        http_message := builder_to_string(*message);

        client: Client;

        set_request_to(*client.request, http_message);

        handled := handle_request(*client, (request: *Request, response: *Response) {
            expect(request.method == "GET");
            expect(request.url == "/");
            expect(request.body == "");

            html(response, "<html>Hello</html>");
        });

        expect(handled);
        expect(client.response.status == .Ok);
        expect(client.response.body == "<html>Hello</html>");
    });

    test("handle_request handles request with a longer url", () {
        message: String_Builder;

        append(*message, "GET /hello/world/hello/world/hello/world HTTP/1.1\r\n");
        append(*message, "\r\n");

        http_message := builder_to_string(*message);

        client: Client;

        set_request_to(*client.request, http_message);

        handled := handle_request(*client, (request: *Request, response: *Response) {
            expect(request.method == "GET");
            expect(request.url == "/hello/world/hello/world/hello/world");
            expect(request.body == "");
        });
    });

    test("handle_request rejects wrong HTTP versions", () {
        message: String_Builder;

        append(*message, "GET / HTTP/2\r\n");
        append(*message, "\r\n");

        http_message := builder_to_string(*message);

        client: Client;

        set_request_to(*client.request, http_message);

        handled := handle_request(*client, (request: *Request, response: *Response) {
            expect(false);
        });

        expect(handled);
        expect(client.response.status == .Bad_Request);
    });
} @test

set_request_to :: (request: *Internal_Request, body: string) {
    memcpy(request.raw.data, body.data, body.count);
    request.raw_count = body.count;
}

#load "../module.jai";
main :: () {
    http_server(8080, (request: *Request, response: *Response) {
        if request.method == {
            case "GET";
                if request.url == {
                    case "/";
                        b: String_Builder;
                        b.allocator = temp;

                        append(*b, #string HTML
                            <html>
                                <head>
                                </head>
                                <body>
                                    <h1>To Do</h1>
                                    <ul>
                        HTML);

                        for todos {
                            append(*b, tprint("<li>%</li>\n", it));
                        }

                        append(*b, #string HTML
                                    </ul>

                                    <a href="/add">Add</a>
                                </body>
                            </html>
                        HTML);

                        html(response, builder_to_string(*b,, temp));

                    case "/add";
                        b: String_Builder;
                        b.allocator = temp;

                        append(*b, #string HTML
                            <html>
                                <head>
                                </head>
                                <body>
                                    <h1>Add To Do</h1>
                        HTML);

            case "PUT";

            case;
                not_found(response);
                return;
        }
    });
}

todos: [..] string;

#import,file "../../module.jai";
#import "Basic";
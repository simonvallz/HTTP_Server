// This example is incomplete but will be completed in the future.

main :: () {
    http_server(8080, (request: *Request, response: *Response) {
        url, query_arguments := parse_query_string(request.url);

        if request.method == {
            case "GET";
                if url == {
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
                        if query_arguments.count == 0 {
                            html(response, #string HTML
                                <html>
                                    <head>
                                    </head>
                                    <body>
                                        <h1>Add To Do</h1>
                                        <form action="/add">
                                            <label for="title">Title</label>
                                            <br>
                                            <input for="title" name="title">
                                        </form>
                                    </body>
                                </html>
                            HTML);
                        } else {
                            todo, found := table_find(*query_arguments, "title");
                            if !found {
                                bad_request(response);
                                return;
                            }

                            array_add(*todos, copy_string(todo));

                            redirect(response, "/");
                        }
                }

            case;
                not_found(response);
                return;
        }
    });
}

parse_query_string :: (url_with_query_string: string) -> url: string, query_arguments: Table(string, string) /* temporary storage */ {
    query_arguments: Table(string, string);
    query_arguments.allocator = temp;

    found, left, right := split_from_left(url_with_query_string, "?");
    if !found  return url_with_query_string, query_arguments;

    parts := split(right, "&",, temp);
    for parts {
        found, left, right := split_from_left(it, "=");
        if !found {
            table_add(*query_arguments, it, "");
            continue;
        }

        table_add(*query_arguments, left, right);
    }

    return left, query_arguments;
}

redirect :: (response: *Response, url: string) {
    b: String_Builder;
    b.allocator = temp;

    append(*b, #string HTML
        <html>
            <head>
                <meta http-equiv="Refresh" content="0; url='
    HTML);

    append(*b, url);

    append(*b, #string HTML
                '" />
            </head>
            <body>
            </body>
        </html>
    HTML);

    response.status = .Ok;
    response.body = builder_to_string(*b,, temp);
}

bad_request :: (response: *Response) {
    response.status = .Bad_Request;
}

todos: [..] string;

#import,file "../../module.jai";
#import "Basic";
#import "Hash_Table";
#import "String";
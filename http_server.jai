http_server :: (port: u16, request_handler: Request_Handler) {
    platform_main_loop(port, request_handler=request_handler);
}

#if TLS {
    http_server_tls :: (port: u16, certificate_file: string, private_key_file: string, request_handler: Request_Handler) {
        platform_main_loop(port, true, certificate_file, private_key_file, request_handler);
    }
}

Request :: struct {
    url:     string;
    method:  string;
    headers: [..] Header;
    headers.allocator = temp;

    body: string;
}

Response :: struct {
    status:       Response_Status;
    headers:      [..] Header;
    headers.allocator = temp;

    body: string; // Allocate with temporary storage!
}

Header :: struct {
    key:   string;
    value: string;
}

set_header :: (headers: *[..] Header, key: string, value: string) {
    for * headers.* {
        if equal_nocase(it.key, key) {
            it.value = value;
            return;
        }
    }

    header: Header = ---;
    header.key = key;
    header.value = value;

    array_add(headers, header);
}

Request_Handler :: #type (request: *Request, response: *Response);

html :: (response: *Response, html: string) {
    response.status = .Ok;
    response.body = html;

    set_header(*response.headers, "Content-Type", "text/html");
}

not_found :: (response: *Response) {
    response.status = .Not_Found;
}

#scope_module

Internal_Request :: struct {
    #as using request: Request;

    #if OS == .WINDOWS {
        buffer: WSABUF;
    }

    raw: [MAX_REQUEST_SIZE] u8;
    raw_count: int;
}

Internal_Response :: struct {
    #as using response: Response;

    #if OS == .WINDOWS {
        buffer: WSABUF;
    }

    serialized: string; // :Free-able
    bytes_sent: int;
}

setup_socket :: (port: u16) -> Socket {
    socket_fd := socket(AF_INET, .SOCK_STREAM, 0);
    if socket_fd == INVALID_SOCKET  fatal("socket");

    #if OS == .LINUX || OS == .MACOS {
        options := 1;
        if setsockopt(socket_fd, SOL_SOCKET, SO_REUSEPORT, *options, size_of(type_of(options))) == -1  fatal("setsockopt");
    }

    if bind(socket_fd, INADDR_ANY, port) != 0  fatal("bind");

    if listen(socket_fd, SOMAXCONN) != 0  fatal("listen");

    set_blocking(socket_fd, #run OS == .WINDOWS);

    return socket_fd;
}

handle_request :: (client: *Client, request_handler: Request_Handler) -> handled: bool {
    message: string = ---;
    message.data = client.request.raw.data;
    message.count = client.request.raw_count;

    found, request_line, rest := split_from_left(message, "\r\n");
    if !found  return false;

    request_parts := split(request_line, " ",, temp);
    if request_parts.count != 3 {
        bad_request(client);
        return true;
    }
    if request_parts[2] != "HTTP/1.1" {
        bad_request(client);
        return true;
    }

    // We maybe don't have any headers.
    if starts_with(rest, "\r\n") {
        count := "\r\n".count;

        rest.data += count;
        rest.count -= count;
    } else {
        found, headers_string:, rest = split_from_left(rest, "\r\n\r\n");
        if !found  return false;

        content_length := 0;

        headers := split(headers_string, "\r\n",, temp);
        for headers {
            found, key, value := split_from_left(it, ":");
            if !found {
                bad_request(client);
                return true;
            }

            key = trim(key, chars=" ");
            value = trim(value, chars=" ");

            set_header(*client.request.headers, key, value);

            if equal_nocase(key, "Content-Length") {
                success: bool;
                content_length, success = parse_int(*copy_temporary_string(value), spaces="", delimiters="");
                if !success || content_length < 0 {
                    bad_request(client);
                    return true;
                }
            }

            if equal_nocase(key, "Connection") && equal_nocase(value, "close") {
                client.close_after_send = true;
            }
        }

        if content_length > rest.count {
            return false;
        } else if content_length < rest.count {
            bad_request(client);
            return true;
        }
    }

    client.request.method = request_parts[0];
    client.request.url = request_parts[1];
    client.request.body = rest;

    if validate_request(*client.request) {
        bad_request(client);
        return true;
    }

    request_handler(*client.request, *client.response);

    if client.response.status == .None  not_found(*client.response);
    send_response(client);

    return true;
}

validate_request :: (request: *Internal_Request) -> invalid: bool {
    if request.method == {
        case "DELETE"; #through;
        case "GET";
            if request.body.count != 0  return true;
        case "HEAD";
            if request.body.count != 0  return true;
        case "OPTIONS";
            if request.body.count != 0  return true;
        case "PATCH"; #through;
        case "PUT"; #through;
        case;
            return true;
    }

    return false;
}

bad_request :: (client: *Client) {
    client.response.status = .Bad_Request;
    client.close_after_send = true;
    send_response(client);
}

not_found :: (client: *Client) {
    client.response.status = .Not_Found;
    send_response(client);
}

send_response :: (client: *Client) {
    b: String_Builder;
    b.allocator = temp;

    if client.close_after_send {
        set_header(*client.response.headers, "Connection", "close");
    } else {
        set_header(*client.response.headers, "Connection", "keep-alive");
        set_header(*client.response.headers, "Keep-Alive", KEEP_ALIVE_HEADER_VALUE);
    }

    set_header(*client.response.headers, "Content-Length", tprint("%", client.response.body.count));

    append(*b, tprint("HTTP/1.1 %\r\n", to_string(client.response.status)));

    for client.response.headers {
        append(*b, tprint("%: %\r\n", it.key, it.value));
    }

    append(*b, "\r\n");

    append(*b, client.response.body);

    client.response.serialized = builder_to_string(*b);
}

reset :: (client: *Client) {
    if client.response.serialized.data != null  free(client.response.serialized.data);

    memset(*client.request, 0, size_of(type_of(client.request)));
    memset(*client.response, 0, size_of(type_of(client.response)));

    client.request.headers.allocator = temp;
    client.response.headers.allocator = temp;
}

Client :: struct {
    #if OS == .WINDOWS {
        overlapped: Windows.OVERLAPPED;
        operation: enum { RECV; SEND; }

        locator: Bucket_Locator;

        ref_count: u8; // Atomic
        shutdown: bool;
    }

    socket_fd: Socket;

    request:  Internal_Request;
    response: Internal_Response;

    close_after_send: bool;

    keep_alive_expiration: Apollo_Time;

    #if TLS {
        ssl: *SSL;
    }
}

fatal :: (message: string) {
    error := get_error_value();
    error_string := get_error_string(error);

    log("% :: [%] %\n", message, error, error_string);

    exit(1);
}

Response_Status :: enum {
    None :: 0;

    // Informational responses.
    Continue            :: 100;
    Switching_Protocols :: 101;
    Early_Hints         :: 103;

    // Successful responses.
    Ok                            :: 200;
    Created                       :: 201;
    Accepted                      :: 202;
    Non_Authoritative_Information :: 203;
    No_Content                    :: 204;
    Reset_Content                 :: 205;
    Partial_Content               :: 206;

    // Redirection messages.
    Multiple_Choices   :: 300;
    Moved_Permanently  :: 301;
    Found              :: 302;
    See_Other          :: 303;
    Not_Modified       :: 304;
    Temporary_Redirect :: 307;
    Permanent_Redirect :: 308;

    // Client error responses.
    Bad_Request                     :: 400;
    Unauthorized                    :: 401;
    Payment_Required                :: 402;
    Forbidden                       :: 403;
    Not_Found                       :: 404;
    Method_Not_Allowed              :: 405;
    Not_Acceptable                  :: 406;
    Proxy_Authentication_Required   :: 407;
    Request_Timeout                 :: 408;
    Conflict                        :: 409;
    Gone                            :: 410;
    Length_Required                 :: 411;
    Precondition_Failed             :: 412;
    Content_Too_Large               :: 413;
    Uri_Too_Long                    :: 414;
    Unsupported_Media_Type          :: 415;
    Range_Not_Satisfiable           :: 416;
    Expectation_Failed              :: 417;
    I_Am_A_Teapot                   :: 418;
    Misdirected_Request             :: 421;
    Upgrade_Required                :: 426;
    Precondition_Required           :: 428;
    Too_Many_Requests               :: 429;
    Request_Header_Fields_Too_Large :: 431;
    Unavailable_For_Legal_Reasons   :: 451;

    // Server error responses.
    Internal_Server_Error           :: 500;
    Not_Implemented                 :: 501;
    Bad_Gateway                     :: 502;
    Service_Unavailable             :: 503;
    Gateway_Timeout                 :: 504;
    Http_Version_Not_Supported      :: 505;
    Variant_Also_Negotiates         :: 506;
    Not_Extended                    :: 510;
    Network_Authentication_Required :: 511;
}

to_string :: (response_status: Response_Status) -> string {
    if #complete response_status == {
        case .None;
            return "None";

        case .Continue;
            return "100 Continue";
        case .Switching_Protocols;
            return "101 Switching Protocols";
        case .Early_Hints;
            return "103 Early Hints";

        case .Ok;
            return "200 OK";
        case .Created;
            return "201 Created";
        case .Accepted;
            return "202 Accepted";
        case .Non_Authoritative_Information;
            return "303 Non-Authoritative Information";
        case .No_Content;
            return "204 No Content";
        case .Reset_Content;
            return "205 Reset Content";
        case .Partial_Content;
            return "206 Partial Content";

        case .Multiple_Choices;
            return "300 Multiple Choices";
        case .Moved_Permanently;
            return "301 Moved Permanently";
        case .Found;
            return "302 Found";
        case .See_Other;
            return "303 See Other";
        case .Not_Modified;
            return "304 Not Modified";
        case .Temporary_Redirect;
            return "307 Temporary Redirect";
        case .Permanent_Redirect;
            return "308 Permanent Redirect";

        case .Bad_Request;
            return "400 Bad Request";
        case .Unauthorized;
            return "401 Unauthorized";
        case .Payment_Required;
            return "402 Payment Required";
        case .Forbidden;
            return "403 Forbidden";
        case .Not_Found;
            return "404 Not Found";
        case .Method_Not_Allowed;
            return "405 Method Not Allowed";
        case .Not_Acceptable;
            return "406 Not Acceptable";
        case .Proxy_Authentication_Required;
            return "407 Proxy Authentication Required";
        case .Request_Timeout;
            return "408 Request Timeout";
        case .Conflict;
            return "409 Conflict";
        case .Gone;
            return "410 Gone";
        case .Length_Required;
            return "411 Length Required";
        case .Precondition_Failed;
            return "412 Precondition Failed";
        case .Content_Too_Large;
            return "413 Content Too Large";
        case .Uri_Too_Long;
            return "414 URI Too Long";
        case .Unsupported_Media_Type;
            return "415 Unsupported Media Type";
        case .Range_Not_Satisfiable;
            return "416 Range Not Satisfiable";
        case .Expectation_Failed;
            return "417 Expectation Failed";
        case .I_Am_A_Teapot;
            return "418 I'm a teapot";
        case .Misdirected_Request;
            return "421 Misdirected Request";
        case .Upgrade_Required;
            return "426 Upgrade Required";
        case .Precondition_Required;
            return "428 Precondition Failed";
        case .Too_Many_Requests;
            return "429 Too Many Requests";
        case .Request_Header_Fields_Too_Large;
            return "431 Request Header Fields Too Large";
        case .Unavailable_For_Legal_Reasons;
            return "451 Unavailable For Legal Reasons";

        case .Internal_Server_Error;
            return "500 Internal Server Error";
        case .Not_Implemented;
            return "501 Not Implemented";
        case .Bad_Gateway;
            return "502 Bad Gateway";
        case .Service_Unavailable;
            return "503 Service Unavailable";
        case .Gateway_Timeout;
            return "504 Gateway Timeout";
        case .Http_Version_Not_Supported;
            return "505 HTTP Version Not Supported";
        case .Variant_Also_Negotiates;
            return "506 Variant Also Negotiates";
        case .Not_Extended;
            return "510 Not Extended";
        case .Network_Authentication_Required;
            return "511 Network Authentication Required";
    }
}

ACCEPT_KEEP_ALIVE :: #run seconds_to_apollo(60);
KEEP_ALIVE        :: #run seconds_to_apollo(600);

KEEP_ALIVE_HEADER_VALUE :: "timeout=600";

MAX_REQUEST_SIZE :: 65536;

#import "Basic";
#import "Socket";
#import "String";
#import "System";
#import "Thread";

#if OS == .LINUX {
    #load "linux.jai";
} else #if OS == .WINDOWS {
    #load "windows.jai";
} else #if OS == .MACOS {
    #load "macos.jai";
} else {
    assert(false, "Operating system not supported...");
}
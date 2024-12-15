main :: () {
    http_server(8080, (request: *Request, response: *Response) {
        // Please note that this procedure can be called on any thread.

        print("% %\n", request.method, request.url);
        html(response, "<html>Hello World!</html>");
    });
}

#import,file "../../module.jai";
#import "Basic";
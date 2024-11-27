main :: () {
    http_server(8080, (request: *Request, response: *Response) {
        html(response, "<html>Hello World!</html>");
    });
}

#import,file "../../module.jai";
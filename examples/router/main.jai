// In the future I would like to have a router for this HTTP server. This router should be optional to use. This below is an example of how I would like the router to work.

main :: () {
    router: Router;

    get(*router, "/", (request: *Request, response: *Response) {});

    put(*router, "/user/:id/name", (request: *request, response: *Response) {});

    http_server(8080, *router);
}

#import,file "../../module.jai";
#import "Basic";
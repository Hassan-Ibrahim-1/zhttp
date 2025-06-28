implement http 1.1
figure out concurrency
figure out javascript / css / html
websockets
databases
https
authentication
security
ftp
rate limiting
instant page reloading on change
telnet
http chunking
http2
caching
cookies

Next up:
    write a server that can send over the contents of a requested file
    be able to setup handlers, routers, etc
    figure out how go's HttpMux works and implement it yourself
    write a response and request struct and add an easy way to 
    write headers, status codes, body stuff and more
    try figuring out how curl works

Be able to parse GET and POST requests
    -- Parse the first line to determine verison, method, status code, etc
    - Parse headers and put them in a map
    - Parse the body using Content-Length
    try writeAll(socket, msg);
    - Figure out how to read from the socket

http uses \r\n as a delimiter for headers and a Content-Length header prefix for the body
create a reader struct that reads a full http message and returns it
wrapped in a request struct. it should keep the rest of the message in a buffer

TOMORROW:
    finish parsing headers
    respond to a basic get request, ignore any body
    read http body in HttpReader using the Content-Length header
    parse body
    be able to accept post requests from stuff like forms
    write a format function for Request that can reproduce the exact
    request that was sent by the client.
    
    get started on responses - should be way easier
    write a format function that constructs a valid http response

    create a web page with a form, image, etc

GET /index.html HTTP/1.1\r\n
Host: www.example.com\r\n
User-Agent: Mozilla/5.0\r\n
Accept: text/html\r\n
Connection: close\r\n
\r\n

a full message is when a \r\n\r\n pattern is encountered
in the unprocessed buffer. if that pattern is found
and there is no Content-Length header then return only that
if there is a Content-Length header then read that many bytes
from the socket


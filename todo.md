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
    - Parse the first line to determine verison, method, status code, etc
    - Parse headers and put them in a map
    - Parse the body using Content-Length
    try writeAll(socket, msg);
    - Figure out how to read from the socket

http uses \r\n as a delimiter for headers and a Content-Length header
prefix for the body
create a reader struct that reads a full http message and returns it
wrapped in a request struct. it should keep the rest of the message in a buffer

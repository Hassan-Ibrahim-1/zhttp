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
rss reader
unix processes

Next up:
    -- write a server that can send over the contents of a requested file
    -- be able to setup handlers, routers, etc
    -- figure out how go's HttpMux works and implement it yourself
    -- write a response and request struct and add an easy way to 
    -- write headers, status codes, body stuff and more
    try figuring out how curl works

Be able to parse GET and POST requests
    -- Parse the first line to determine verison, method, status code, etc
    -- Parse headers and put them in a map
    -- Parse the body using Content-Length
    -- Figure out how to read from the socket

GOAL:
    be able to create a blog website where i can add markdown
    files in a directory and the server will construct handlers based on that
    things i want
        - creating a file server in a specific directory
            maybe have it be configurable so it only sends certain types of files
            or only send non-hidden files, or restrict certain files specifically
        - live reloading
            edit the md file and have the changes appear on the website automatically
            without have to reload the web page manually
            same for handlers, if a new file is created make a new handler for it
        - be able to style the document without having to write css
        - some basic interactivity like links, buttons that act as links etc
        - be able to add a top bar that has some links and some personalized text
            look at other blogs for inspiration
            https://neilonsoftware.com/blog/
            https://lethain.com/
            https://benhoyt.com/writings/how-to-apply/
        - a home page with some basic info
        - being able to include code snippets with syntax highlighting
            a neovim plugin for this would be cool as well
            in an md code snippet maybe that code could have its own syntax highlighting (in editor)
        - an articles page with a list of articles that can have custom styling
            being able to have optional descriptions of articles
        - being able to comment on an article and interacting with comments (likes, replies)
        - maybe add an audio feature so that some blogs can optionally be podcasts
        - make it secure (figure out what this means)
        - RSS
        - be able to override css
        - changing font

TOMORROW:
    make isPrefixOf and findBestRoute better. they are really inefficient and dirty
    fix up the dirty code in FileServer and StripPrefix, some repeated stuff, etc
        just go through it

    concurrency
        this is big
        
        how to test this:
            connect multiple clients to the server. each sends a request to the server
            have the server wait for at most 2 seconds max before responding with some basic json
            the entire thing should take at most 2 seconds to finish, it should not compound
            mocking would be great for this but get some basic concurrency done first

        design:
            this is really confusing - stop reading so much and just implement
                do go through the book on semaphores though at some point
            epoll / kqueue backend for async io
            threads...
                figure out an efficient version of std.Thread.Pool.
                threads are expensive
                only one thread can write / read from a single socket

        this is just the producer consumer problem
            have a thread read http requests from clients and put
            them in a request queue.
            then have n worker threads go through the request queue
            and process those requests and generate responses
    
            i still need to figure out how to read and write messages
            should it be done via multiple threads, like multiple threads
            can read messages from clients while other threads can
            simultaneously write to those clients
            or should the main thread be the only one allowed to 
            interface with clients at all


            main thread reads from a socket and parses the request
            dispatch that request to a handler that runs in a worker thread (this is where a queue comes in)
            the worker thread then updates the client to poll for writes and the main thread then writes the
            response to the client

            the dispatching part can be optimized so that if the resource is a static resource like for a fileserver
            then just call the handler on the main thread. investigate this at some point

            for read to be done in the main thread thttp.HttpReader would also have to be non blocking

    a client that can make requests a server
    a mocking library that can spin up a server and client.
        use this to test functions that require sockets
    maybe this is possible in the normal testing stuff

    add more tests for parsing
    add more tests in general, isolate stuff that can be isolated
        end to end tests using the mocking library i'll eventually write


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
    -- finish parsing headers
    -- respond to a basic get request, ignore any body
    -- read http body in HttpReader using the Content-Length header
    -- parse body
    -- url parsing
    -- be able to accept post requests from stuff like forms
    -- write a format function for Request that can reproduce the exact request that was sent by the client.
    got error.WouldBlock when sending a request back after the button was pressed
    
    -- get started on responses - should be way easier
    -- write a format function that constructs a valid http response

    -- add a handler / router
        -- automatically create the Content-Length header
        -- figure out how to handle routes like /api/user/{id}

    make isPrefixOf and findBestRoute better. they are really inefficient and dirty
    fix up the dirty code in FileServer and StripPrefix, some repeated stuff, etc
        just go through it

    create a web page with a form, image, etc

    add checks for Responses
        valid headers
        status code

    add more tests for parsing
    a client that can make requests a server
    a mocking library that can spin up a server and client.
        use this to test functions that require sockets
    maybe this is possible in the normal testing stuff

    concurrency
        spawn a new thread for each client / handler


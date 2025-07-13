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
    -- KQueue

    make isPrefixOf and findBestRoute better. they are really inefficient and dirty
    fix up the dirty code in FileServer and StripPrefix, some repeated stuff, etc
        just go through it
    
    clean up allocation if an error occurs

    how to test this:
        connect multiple clients to the server. each sends a request to the server
        have the server wait for at most 2 seconds max before responding with some basic json
        the entire thing should take at most 2 seconds to finish, it should not compound
        mocking would be great for this but get some basic concurrency done first

    -- a client that can make requests a server
    a mocking library that can spin up a server and client.
        use this to test functions that require sockets
    maybe this is possible in the normal testing stuff

    add more tests for parsing
    add more tests in general, isolate stuff that can be isolated
        end to end tests using the mocking library i'll eventually write

    when the server is listening add an override for ctrl-c so that it stops
    listening and cleans up appropriately. im not getting any mem leak info 
    because of this.
    
    implement RFC properly. actually go through it properly
        headers like Connection: keep-alive, Expect: 100-Continue, are not handled properly
        urls are not done right, things like the connect and options method can have different url formats
        much much more

    mocking
        a function that takes in a type and calls every function in it that starts with test
        helper functions that create a server, add handlers etc
        maybe setup a mock directory
    
        full end to end tests. there should be asserts along the way, things that are
        impossible to happen should never happen. 

        These should work on macos as well!!
        what tests to support:
            * creating the server and listening on a socket
            * adding handlers
            * handling errors and bad requests appropriately
            * what should happen when no handlers are present?
            * HttpReader: have the client send out little chunks of an http message at a time and have it send 
              out multiple requests in a row from the same port. (have to implement Connection: Keep-alive for this)
            * HttpWriter: just make sure the right response is sent back
            * proper cleanup of resources, make sure nothing is left unfreed
            * make sure every socket is closed properly
            * send invalid headers to the server. stuff like "H !@#: Bad&*Header"
            * send non http messages. just random streams of bytes and the server
              should properly respond without crashing. the connection should just be severed
            * test custom handlers like FileServer and StripPrefix. make sure they actually work
            * send invalid mime types. server should recognize this
            * send bad http requests that can mess up the parser. server should response approriately
            * make sure the server can never send an invalid Response
            * make sure handler deinit works.
            * async/io: send multiple requests simultaneously (1000s) and expect valid responses
              within a reasonable time frame
            * when rfc is fully implemented, make sure all the edge-cases / expected behavior is covered
                by this i mean things like the Expect and Connection headers
            * make sure clients are properly timed out (when timeouts are actually implemented)

        benchmark:
            figure out how to measure requests / second

    testing strat
        send a request and wait for a response
        assert that the response is what was expected

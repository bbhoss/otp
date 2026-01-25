/*
 * MQuickJS Erlang C Node - Main Entry Point
 *
 * This is the main executable for the MQuickJS C node. It:
 *   1. Parses command-line arguments
 *   2. Initializes the Erlang interface (ei)
 *   3. Connects to the Erlang VM as a hidden node
 *   4. Initializes the JavaScript runtime
 *   5. Enters the message processing loop
 *   6. Cleans up on shutdown
 *
 * Usage:
 *   mquickjs_cnode -n nodename -c cookie -e erlang_node [-m memsize]
 *
 * The C node connects to the specified Erlang node and waits for
 * commands. It runs until it receives a 'stop' command or the
 * connection is lost.
 *
 * See mquickjs_cnode.h for the complete API documentation.
 *
 * Copyright Ericsson AB 2025. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0
 */

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <errno.h>

#ifndef _WIN32
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#endif

#include "mquickjs_cnode.h"

/*
 * ============================================================================
 * Signal Handling
 * ============================================================================
 */

/**
 * Signal handler for graceful shutdown.
 *
 * Catches SIGINT (Ctrl+C) and SIGTERM to allow clean shutdown.
 * Sets g_running to 0, which causes the main loop to exit.
 */
static void signal_handler(int sig)
{
    (void)sig;  /* Unused */
    g_running = 0;
}

/*
 * ============================================================================
 * Command-Line Interface
 * ============================================================================
 */

/**
 * Print usage information.
 *
 * Displayed when -h is passed or when required arguments are missing.
 */
static void usage(const char *progname)
{
    fprintf(stderr, "MQuickJS Erlang C Node\n\n");
    fprintf(stderr, "Usage: %s -n nodename -c cookie -e erlang_node [-m memsize]\n\n",
            progname);
    fprintf(stderr, "Required arguments:\n");
    fprintf(stderr, "  -c cookie      : Erlang cookie for authentication\n");
    fprintf(stderr, "  -e erlang_node : Erlang node name to connect to\n\n");
    fprintf(stderr, "Optional arguments:\n");
    fprintf(stderr, "  -n nodename    : Name for this C node (default: mquickjs)\n");
    fprintf(stderr, "  -m memsize     : JavaScript memory size in KB (default: 256)\n");
    fprintf(stderr, "  -h             : Show this help message\n\n");
    fprintf(stderr, "Example:\n");
    fprintf(stderr, "  %s -n myjs -c mycookie -e mynode@localhost -m 512\n", progname);
}

/*
 * ============================================================================
 * Main Function
 * ============================================================================
 */

int main(int argc, char *argv[])
{
    /* Command-line options */
    int opt;
    const char *nodename = "mquickjs";
    const char *cookie = NULL;
    const char *erlang_node = NULL;
    size_t mem_size = DEFAULT_MEM_SIZE;

    /* Erlang interface state */
    ei_cnode ec;
    int fd = -1;
    erlang_msg msg;
    ei_x_buff buf;
    int got;

    /*
     * Parse command-line arguments.
     *
     * Required: -c (cookie), -e (erlang node)
     * Optional: -n (nodename), -m (memory size), -h (help)
     */
    while ((opt = getopt(argc, argv, "n:c:e:m:h")) != -1) {
        switch (opt) {
        case 'n':
            nodename = optarg;
            break;
        case 'c':
            cookie = optarg;
            break;
        case 'e':
            erlang_node = optarg;
            break;
        case 'm':
            mem_size = (size_t)atol(optarg) * 1024;
            break;
        case 'h':
        default:
            usage(argv[0]);
            return opt == 'h' ? 0 : 1;
        }
    }

    /* Validate required arguments */
    if (!cookie) {
        fprintf(stderr, "Error: Cookie is required (-c)\n\n");
        usage(argv[0]);
        return 1;
    }

    if (!erlang_node) {
        fprintf(stderr, "Error: Erlang node is required (-e)\n\n");
        usage(argv[0]);
        return 1;
    }

    /*
     * Set up signal handlers for graceful shutdown.
     *
     * SIGINT  - Ctrl+C from terminal
     * SIGTERM - Termination request (e.g., from process manager)
     * SIGPIPE - Ignore broken pipe (connection lost)
     */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
#ifndef _WIN32
    signal(SIGPIPE, SIG_IGN);
#endif

    /*
     * Initialize the Erlang interface.
     *
     * ei_init() sets up internal state for the ei library.
     * Must be called before any other ei functions.
     */
    if (ei_init() < 0) {
        fprintf(stderr, "Failed to initialize ei library\n");
        return 1;
    }

    /*
     * Initialize this C node.
     *
     * Creates a node identity with the specified name and cookie.
     * The cookie must match the Erlang node we're connecting to.
     */
    if (ei_connect_init(&ec, nodename, cookie, 0) < 0) {
        fprintf(stderr, "Failed to initialize C node: %s\n", strerror(erl_errno));
        return 1;
    }

    fprintf(stderr, "C node '%s' initialized\n", ei_thisnodename(&ec));

    /*
     * Connect to the Erlang node.
     *
     * This establishes a TCP connection to the specified Erlang node.
     * The C node appears as a hidden node (not visible in nodes()).
     */
    fd = ei_connect(&ec, (char *)erlang_node);
    if (fd < 0) {
        fprintf(stderr, "Failed to connect to Erlang node '%s': %s\n",
                erlang_node, strerror(erl_errno));
        return 1;
    }

    fprintf(stderr, "Connected to Erlang node '%s'\n", erlang_node);

    /*
     * Initialize the JavaScript runtime.
     *
     * Creates the MQuickJS context with the specified memory size.
     * This must succeed before we can process eval commands.
     */
    if (js_runtime_init(mem_size) < 0) {
        fprintf(stderr, "Failed to initialize JavaScript context\n");
        ei_close_connection(fd);
        return 1;
    }

    fprintf(stderr, "JavaScript context initialized (mem_size=%zu bytes)\n",
            js_runtime_get_mem_size());

    /*
     * Main message processing loop.
     *
     * Receives messages from Erlang and dispatches them to handlers.
     * Continues until:
     *   - g_running is set to 0 (by 'stop' command or signal)
     *   - Connection error occurs
     */
    ei_x_new(&buf);

    while (g_running) {
        /* Receive next message (blocking) */
        got = ei_xreceive_msg(fd, &msg, &buf);

        if (got == ERL_TICK) {
            /* Keepalive tick - just continue */
            continue;
        }

        if (got == ERL_ERROR) {
            /* Check for recoverable errors */
            if (erl_errno == EAGAIN || erl_errno == EINTR) {
                continue;
            }
            /* Unrecoverable error - exit loop */
            fprintf(stderr, "Receive error: %s\n", strerror(erl_errno));
            break;
        }

        /* Process regular messages (send/reg_send) */
        if (msg.msgtype == ERL_SEND || msg.msgtype == ERL_REG_SEND) {
            process_message(fd, &msg.from, &buf);
        }
    }

    /*
     * Cleanup.
     *
     * Free all resources in reverse order of allocation.
     */
    ei_x_free(&buf);
    js_runtime_cleanup();

    if (fd >= 0) {
        ei_close_connection(fd);
    }

    fprintf(stderr, "C node shutting down\n");
    return 0;
}

//
// yabai-msg: send a message to a running yabai instance.
//
// Equivalent to `yabai -m <args>`, but links only libSystem, so it skips loading
// Cocoa/SkyLight on every invocation. Keep the wire format in sync with
// client_send_message in yabai.c.
//

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCKET_PATH_FMT "/tmp/yabai_%s.socket"
#define FAILURE_MESSAGE '\x07'

static int fail(const char *message)
{
    fprintf(stderr, "yabai-msg: %s\n", message);
    return EXIT_FAILURE;
}

int main(int argc, char **argv)
{
    if (argc <= 1) return fail("no arguments given! abort..");

    char *user = getenv("USER");
    if (!user) return fail("'env USER' not set! abort..");

    int message_length = argc;
    for (int i = 1; i < argc; ++i) {
        message_length += strlen(argv[i]);
    }

    char *message = malloc(sizeof(int)+message_length);
    char *temp = message + sizeof(int);

    memcpy(message, &message_length, sizeof(int));
    for (int i = 1; i < argc; ++i) {
        size_t length = strlen(argv[i]);
        memcpy(temp, argv[i], length);
        temp += length;
        *temp++ = '\0';
    }
    *temp++ = '\0';

    struct sockaddr_un address = { .sun_family = AF_UNIX };
    snprintf(address.sun_path, sizeof(address.sun_path), SOCKET_PATH_FMT, user);

    int sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sockfd == -1) return fail("failed to open socket..");

    if (connect(sockfd, (struct sockaddr *) &address, sizeof(address)) == -1) {
        return fail("failed to connect to socket..");
    }

    if (send(sockfd, message, sizeof(int)+message_length, 0) == -1) {
        return fail("failed to send data..");
    }

    shutdown(sockfd, SHUT_WR);
    free(message);

    int result = EXIT_SUCCESS;
    FILE *output = stdout;
    bool first_chunk = true;
    char rsp[BUFSIZ];
    ssize_t bytes_read;

    while ((bytes_read = read(sockfd, rsp, sizeof(rsp))) > 0) {
        char *data = rsp;

        if (first_chunk && rsp[0] == FAILURE_MESSAGE) {
            result = EXIT_FAILURE;
            output = stderr;
            ++data;
            --bytes_read;
        }

        first_chunk = false;
        fwrite(data, 1, bytes_read, output);
    }

    fflush(output);
    close(sockfd);
    return result;
}

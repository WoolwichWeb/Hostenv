#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>

/* Create subdirectories relative to an already opened directory. */
int hostenv_endpoint_make_directory(int parent, const char *name)
{
    return mkdirat(parent, name, 0700);
}

int hostenv_endpoint_socket_matches(int fd, const char *path)
{
    int domain, type, accepting;
    socklen_t optlen = sizeof(int);
    if (getsockopt(fd, SOL_SOCKET, SO_DOMAIN, &domain, &optlen) < 0)
        return -1;
    optlen = sizeof(int);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &optlen) < 0)
        return -1;
    optlen = sizeof(int);
    if (getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &accepting, &optlen) < 0)
        return -1;
    if (domain != AF_UNIX || type != SOCK_STREAM || accepting != 1)
        return 0;

    struct sockaddr_un address = {0};
    socklen_t length = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &length) < 0)
        return -1;
    size_t path_length = strlen(path);
    if (address.sun_family != AF_UNIX ||
        path_length >= sizeof(address.sun_path) ||
        length < offsetof(struct sockaddr_un, sun_path) + path_length + 1)
        return 0;
    return memcmp(address.sun_path, path, path_length + 1) == 0;
}

int hostenv_endpoint_pidfd_open(pid_t pid)
{
    return (int)syscall(SYS_pidfd_open, pid, 0);
}

/* Returns 1 if exited, 0 if alive, -1 for a syscall error. */
int hostenv_endpoint_pidfd_exited(int fd, int milliseconds)
{
    struct pollfd item = {.fd = fd, .events = POLLIN};
    int result;
    do {
        result = poll(&item, 1, milliseconds);
    } while (result < 0 && errno == EINTR);
    if (result <= 0)
        return result;
    return (item.revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0;
}

int hostenv_endpoint_pidfd_signal(int fd, int number)
{
    return (int)syscall(SYS_pidfd_send_signal, fd, number, NULL, 0);
}

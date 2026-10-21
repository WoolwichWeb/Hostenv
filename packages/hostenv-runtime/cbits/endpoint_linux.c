#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
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

/* Recover only a socket left behind without an active listener. Never
 * remove a different object that replaced it while we were checking. */
int hostenv_endpoint_recover_stale_socket(int parent, const char *name, const char *path)
{
    struct stat initial, current;
    if (fstatat(parent, name, &initial, AT_SYMLINK_NOFOLLOW) < 0)
        return errno == ENOENT ? 0 : -1;
    if (!S_ISSOCK(initial.st_mode) || initial.st_uid != geteuid())
        return 1;

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    size_t size = strlen(path);
    if (size >= sizeof(address.sun_path)) {
        close(fd);
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(address.sun_path, path, size + 1);
    int connected = connect(fd, (struct sockaddr *)&address,
                            offsetof(struct sockaddr_un, sun_path) + size + 1);
    int error = errno;
    close(fd);
    if (connected == 0 || error != ECONNREFUSED)
        return 1;
    if (fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) < 0)
        return errno == ENOENT ? 0 : -1;
    if (!S_ISSOCK(current.st_mode) || current.st_uid != initial.st_uid ||
        current.st_dev != initial.st_dev || current.st_ino != initial.st_ino)
        return 1;
    return unlinkat(parent, name, 0);
}

/* Only used for possible dual-stack IPv6 sockets, from inside the owner's
 * private network namespace. A successful connection is immediately closed. */
int hostenv_endpoint_probe_ipv4(int port)
{
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_in address = { .sin_family = AF_INET,
                                   .sin_port = htons((unsigned short)port) };
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
    int error = errno;
    if (result < 0 && error == EINPROGRESS) {
        struct pollfd item = { .fd = fd, .events = POLLOUT };
        int ready = poll(&item, 1, 500);
        if (ready > 0) {
            int so_error = 0;
            socklen_t length = sizeof(so_error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_error, &length) == 0)
                result = so_error == 0 ? 0 : -1;
        }
    }
    close(fd);
    return result == 0 ? 1 : 0;
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

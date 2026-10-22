#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <linux/inet_diag.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/sock_diag.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
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

/* Inspect the kernel's IPv6 listener table without connecting to the
 * application. Inet-diag reports IPV6_V6ONLY for listening sockets.
 * Returns 1 for a dual-stack wildcard listener, 0 otherwise, -1 on error. */
int hostenv_endpoint_ipv6_accepts_ipv4(int port)
{
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_SOCK_DIAG);
    if (fd < 0)
        return -1;
    struct timeval deadline = {.tv_sec = 2};
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, sizeof(deadline)) < 0) {
        int error = errno;
        close(fd);
        errno = error;
        return -1;
    }
    struct {
        struct nlmsghdr header;
        struct inet_diag_req_v2 request;
    } query = {0};
    query.header.nlmsg_len = NLMSG_LENGTH(sizeof(query.request));
    query.header.nlmsg_type = SOCK_DIAG_BY_FAMILY;
    query.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    query.header.nlmsg_seq = 1;
    query.request.sdiag_family = AF_INET6;
    query.request.sdiag_protocol = IPPROTO_TCP;
    query.request.idiag_states = 1u << 10; /* TCP_LISTEN */
    struct sockaddr_nl kernel = {.nl_family = AF_NETLINK};
    if (sendto(fd, &query, query.header.nlmsg_len, 0,
               (struct sockaddr *)&kernel, sizeof(kernel)) < 0) {
        int error = errno;
        close(fd);
        errno = error;
        return -1;
    }
    int result = 0;
    int error = 0;
    int done = 0;
    while (!done) {
        char buffer[65536];
        ssize_t got = recv(fd, buffer, sizeof(buffer), MSG_TRUNC);
        if (got < 0) {
            if (errno == EINTR)
                continue;
            error = errno;
            break;
        }
        if (got == 0 || got > (ssize_t)sizeof(buffer)) {
            error = EMSGSIZE;
            break;
        }
        int left = (int)got;
        for (struct nlmsghdr *message = (struct nlmsghdr *)buffer;
             NLMSG_OK(message, left);
             message = NLMSG_NEXT(message, left)) {
            if (message->nlmsg_seq != 1)
                continue;
            if (message->nlmsg_type == NLMSG_DONE) {
                if (message->nlmsg_flags & NLM_F_DUMP_INTR)
                    error = EINTR;
                done = 1;
                break;
            }
            if (message->nlmsg_type == NLMSG_ERROR) {
                if (message->nlmsg_len >= NLMSG_LENGTH(sizeof(struct nlmsgerr))) {
                    const struct nlmsgerr *reply = NLMSG_DATA(message);
                    error = reply->error < 0 ? -reply->error : EIO;
                } else {
                    error = EPROTO;
                }
                done = 1;
                break;
            }
            if (message->nlmsg_type != SOCK_DIAG_BY_FAMILY ||
                message->nlmsg_len < NLMSG_LENGTH(sizeof(struct inet_diag_msg)))
                continue;
            struct inet_diag_msg *listener = NLMSG_DATA(message);
            if (listener->idiag_family != AF_INET6 ||
                ntohs(listener->id.idiag_sport) != port)
                continue;
            uint32_t zeros[4] = {0};
            if (memcmp(listener->id.idiag_src, zeros, sizeof(zeros)) != 0)
                continue;
            int attrs = (int)(message->nlmsg_len - NLMSG_LENGTH(sizeof(*listener)));
            struct rtattr *attr = (struct rtattr *)((char *)listener + NLMSG_ALIGN(sizeof(*listener)));
            for (; RTA_OK(attr, attrs); attr = RTA_NEXT(attr, attrs)) {
                if (attr->rta_type == INET_DIAG_SKV6ONLY && RTA_PAYLOAD(attr) >= 1 &&
                    *(const unsigned char *)RTA_DATA(attr) == 0) {
                    result = 1;
                    done = 1;
                    break;
                }
            }
            if (done)
                break;
        }
    }
    close(fd);
    if (error) {
        errno = error;
        return -1;
    }
    return result;
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

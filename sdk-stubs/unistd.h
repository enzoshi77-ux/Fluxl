// Minimal POSIX surface used by the crash logger. Values are declared here
// because the stub build has no Apple SDK; every symbol resolves against the
// host's libsystem at load time.
#ifndef NBF_STUB_UNISTD_H
#define NBF_STUB_UNISTD_H

#include <stddef.h>

typedef long ssize_t;
typedef long off_t;

ssize_t write(int fd, const void *buf, size_t count);
int close(int fd);
int fsync(int fd);
int unlink(const char *path);
int getpid(void);

#endif

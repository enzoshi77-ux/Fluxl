#ifndef NBF_STUB_SIGNAL_H
#define NBF_STUB_SIGNAL_H

typedef int sig_atomic_t;
typedef void (*sighandler_t)(int);

#define SIG_DFL ((sighandler_t)0)
#define SIG_IGN ((sighandler_t)1)

#define SIGINT   2
#define SIGILL   4
#define SIGTRAP  5
#define SIGABRT  6
#define SIGFPE   8
#define SIGKILL  9
#define SIGBUS  10
#define SIGSEGV 11
#define SIGTERM 15

sighandler_t signal(int sig, sighandler_t handler);
int raise(int sig);

#endif

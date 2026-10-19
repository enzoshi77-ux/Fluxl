#ifndef NBF_STUB_DISPATCH_H
#define NBF_STUB_DISPATCH_H

#include <stdint.h>
#include <stddef.h>

typedef void *dispatch_queue_t;
typedef uint64_t dispatch_time_t;
typedef long dispatch_once_t;

#define DISPATCH_TIME_NOW 0ull
#define NSEC_PER_SEC 1000000000ull

dispatch_time_t dispatch_time(dispatch_time_t when, int64_t delta);
dispatch_queue_t dispatch_get_main_queue(void);
void dispatch_after(dispatch_time_t when, dispatch_queue_t queue, void (^block)(void));
void dispatch_once(dispatch_once_t *predicate, void (^block)(void));

#endif

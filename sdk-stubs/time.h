#ifndef NBF_STUB_TIME_H
#define NBF_STUB_TIME_H

typedef long time_t;

time_t time(time_t *out);
char *ctime(const time_t *clock);
char *ctime_r(const time_t *clock, char *buffer);

#endif

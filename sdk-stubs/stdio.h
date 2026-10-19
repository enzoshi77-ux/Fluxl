#ifndef NBF_STUB_STDIO_H
#define NBF_STUB_STDIO_H

#include <stddef.h>

typedef struct __sFILE FILE;

FILE *fopen(const char *path, const char *mode);
int fputs(const char *s, FILE *stream);
int fclose(FILE *stream);
int snprintf(char *buf, size_t size, const char *fmt, ...);
int printf(const char *fmt, ...);

#endif

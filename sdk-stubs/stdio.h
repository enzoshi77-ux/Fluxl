#ifndef NBF_STUB_STDIO_H
#define NBF_STUB_STDIO_H

#include <stddef.h>

typedef struct __sFILE FILE;

FILE *fopen(const char *path, const char *mode);
int fputs(const char *s, FILE *stream);
int fclose(FILE *stream);
int fflush(FILE *stream);
int fileno(FILE *stream);
size_t fread(void *ptr, size_t size, size_t count, FILE *stream);
int fseek(FILE *stream, long offset, int whence);
long ftell(FILE *stream);
int snprintf(char *buf, size_t size, const char *fmt, ...);
int printf(const char *fmt, ...);

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#endif

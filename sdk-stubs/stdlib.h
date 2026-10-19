#ifndef NBF_STUB_STDLIB_H
#define NBF_STUB_STDLIB_H

#include <stddef.h>

char *getenv(const char *name);
void *malloc(size_t size);
void *calloc(size_t count, size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);
unsigned int arc4random(void);
unsigned int arc4random_uniform(unsigned int upper_bound);

#endif

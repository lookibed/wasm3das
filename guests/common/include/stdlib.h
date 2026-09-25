/* The freestanding libc of Eden ABI guests (guests/common/eden_libc.c). */
#ifndef EDEN_LIBC_STDLIB_H
#define EDEN_LIBC_STDLIB_H

#include <stddef.h>

void *malloc(size_t size);
void free(void *ptr);
void *realloc(void *ptr, size_t size);
void *calloc(size_t count, size_t size);
int abs(int value);
long labs(long value);
int atoi(const char *text);
long strtol(const char *text, char **end, int base);
void exit(int code) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));

#endif

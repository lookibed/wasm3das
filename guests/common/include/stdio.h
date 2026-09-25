/*
 * The freestanding libc of Eden ABI guests (guests/common/eden_libc.c).
 *
 * stdout and stderr are line-buffered into eden_core.log (INFO / WARN).
 * Files are named blobs:
 *   "r"/"rb"        a blob of eden_storage, else a host asset (eden_asset)
 *   "w"/"wb"        a new eden_storage blob, written on fclose / fflush
 *   "a"/"ab"        the existing blob (or an asset's bytes) plus appended data
 *   "+" modes       refused (NULL)
 * remove() deletes an eden_storage blob.
 */
#ifndef EDEN_LIBC_STDIO_H
#define EDEN_LIBC_STDIO_H

#include <stdarg.h>
#include <stddef.h>

typedef struct FILE FILE;

extern FILE *stdout;
extern FILE *stderr;

#define EOF (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

int printf(const char *format, ...) __attribute__((format(printf, 1, 2)));
int fprintf(FILE *stream, const char *format, ...) __attribute__((format(printf, 2, 3)));
int vfprintf(FILE *stream, const char *format, va_list args);
int snprintf(char *buffer, size_t size, const char *format, ...) __attribute__((format(printf, 3, 4)));
int vsnprintf(char *buffer, size_t size, const char *format, va_list args);
int puts(const char *text);
int fputs(const char *text, FILE *stream);
int putchar(int ch);
int fflush(FILE *stream);

FILE *fopen(const char *filename, const char *mode);
int fclose(FILE *stream);
size_t fread(void *buffer, size_t size, size_t count, FILE *stream);
size_t fwrite(const void *buffer, size_t size, size_t count, FILE *stream);
int fseek(FILE *stream, long offset, int origin);
long ftell(FILE *stream);
int remove(const char *filename);

#endif

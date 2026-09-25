/*
 * eden_libc.c: the freestanding C runtime of Eden ABI guests.
 *
 * Built with -ffreestanding (so the compiler never turns these loops back
 * into calls to themselves). Everything is real, nothing is a stub:
 *   - malloc/free/realloc/calloc: first-fit free list over the heap after
 *     __heap_base, growing linear memory with memory.grow; adjacent free
 *     blocks coalesce; a corrupted header aborts the guest
 *   - stdout/stderr: line-buffered into eden_core.log (INFO / WARN)
 *   - files are named blobs: reads from eden_storage, else eden_asset;
 *     writes buffer in memory and become an eden_storage blob on fflush /
 *     fclose; remove() deletes a blob (stdio.h has the modes)
 *   - exit/abort/assert: eden_core.abort with the reason (the export call
 *     fails with it, the instance is faulted)
 *   - eden_alloc/eden_free: the allocator exports every eden_game world
 *     requires
 * printf supports the flags - 0 + space, width, .precision (also *), the
 * length modifiers hh h l ll z j t, and the conversions d i u o x X c s p f %.
 */
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#include "eden/eden_core.h"
#include "eden/eden_asset.h"
#include "eden/eden_storage.h"
#include "eden/eden_game.h"

#include "stdio.h"
#include "stdlib.h"
#include "string.h"

/* ------------------------------------------------------------------------ */
/* Termination                                                               */
/* ------------------------------------------------------------------------ */

static void fatal(const char *message) __attribute__((noreturn));
static void fatal(const char *message) {
    eden_core_abort_z(message);
    __builtin_unreachable();
}

void exit(int code) {
    char text[48];
    snprintf(text, sizeof text, "exit(%d)", code);
    fflush(stdout);
    fflush(stderr);
    fatal(text);
}

void abort(void) {
    fflush(stdout);
    fflush(stderr);
    fatal("abort()");
}

void eden_libc_assert_fail(const char *expr, const char *file, int line) {
    char text[256];
    snprintf(text, sizeof text, "assertion failed: %s (%s:%d)", expr, file, line);
    fflush(stdout);
    fflush(stderr);
    fatal(text);
}

/* ------------------------------------------------------------------------ */
/* Heap                                                                      */
/* ------------------------------------------------------------------------ */

extern unsigned char __heap_base;

#define HEAP_ALIGN 16u
#define HEAP_MAGIC_USED 0xA110C8EDu
#define HEAP_MAGIC_FREE 0xF4EEB10Cu
#define WASM_PAGE 65536u

/* one header per block, blocks in address order; the payload follows the
 * header and is `size` bytes (a multiple of HEAP_ALIGN) */
typedef struct Block {
    size_t size;
    uint32_t magic;
    struct Block *prev; /* previous block in memory, NULL for the first */
    uint32_t pad;       /* keeps the header at 16 bytes on wasm32 */
} Block;

_Static_assert(sizeof(Block) == 16, "Block header must stay 16 bytes");

static Block *heap_first;
static Block *heap_last;
static uintptr_t heap_end; /* first byte past the last block */

static size_t align_up(size_t n) {
    return (n + (HEAP_ALIGN - 1u)) & ~(size_t)(HEAP_ALIGN - 1u);
}

static Block *block_next(Block *b) {
    return b == heap_last ? NULL : (Block *)((unsigned char *)(b + 1) + b->size);
}

static void check_block(Block *b) {
    if (b->magic != HEAP_MAGIC_USED && b->magic != HEAP_MAGIC_FREE) {
        fatal("heap corruption: bad block header");
    }
}

/* makes [heap_end, heap_end + bytes) addressable; 0 on failure */
static int heap_extend(size_t bytes) {
    uintptr_t want = heap_end + bytes;
    uintptr_t have = (uintptr_t)__builtin_wasm_memory_size(0) * WASM_PAGE;
    if (want < heap_end) {
        return 0;
    }
    if (want > have) {
        size_t pages = (size_t)((want - have + WASM_PAGE - 1u) / WASM_PAGE);
        if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) {
            return 0;
        }
    }
    return 1;
}

static void heap_init(void) {
    heap_end = ((uintptr_t)&__heap_base + (HEAP_ALIGN - 1u)) & ~(uintptr_t)(HEAP_ALIGN - 1u);
    heap_first = NULL;
    heap_last = NULL;
}

/* splits b so it keeps `size` bytes, when the rest can hold a block */
static void split(Block *b, size_t size) {
    if (b->size >= size + sizeof(Block) + HEAP_ALIGN) {
        Block *rest = (Block *)((unsigned char *)(b + 1) + size);
        rest->size = b->size - size - sizeof(Block);
        rest->magic = HEAP_MAGIC_FREE;
        rest->prev = b;
        rest->pad = 0;
        Block *after = block_next(b);
        if (after) {
            after->prev = rest;
        } else {
            heap_last = rest;
        }
        b->size = size;
    }
}

void *malloc(size_t request) {
    if (heap_end == 0) {
        heap_init();
    }
    if (request == 0) {
        request = 1;
    }
    if (request > (size_t)0x7fff0000u) {
        return NULL;
    }
    size_t size = align_up(request);
    for (Block *b = heap_first; b; b = block_next(b)) {
        check_block(b);
        if (b->magic == HEAP_MAGIC_FREE && b->size >= size) {
            split(b, size);
            b->magic = HEAP_MAGIC_USED;
            return b + 1;
        }
    }
    /* grow the last free block, or append a new one */
    if (heap_last && heap_last->magic == HEAP_MAGIC_FREE) {
        size_t more = size - heap_last->size;
        if (!heap_extend(more)) {
            return NULL;
        }
        heap_last->size = size;
        heap_last->magic = HEAP_MAGIC_USED;
        heap_end += more;
        return heap_last + 1;
    }
    if (!heap_extend(sizeof(Block) + size)) {
        return NULL;
    }
    Block *b = (Block *)heap_end;
    b->size = size;
    b->magic = HEAP_MAGIC_USED;
    b->prev = heap_last;
    b->pad = 0;
    if (!heap_first) {
        heap_first = b;
    }
    heap_last = b;
    heap_end += sizeof(Block) + size;
    return b + 1;
}

/* merges b with the free block after it */
static void merge_next(Block *b) {
    Block *n = block_next(b);
    if (n && n->magic == HEAP_MAGIC_FREE) {
        b->size += sizeof(Block) + n->size;
        Block *after = block_next(n); /* n is still valid: read before overwrite */
        if (n == heap_last) {
            heap_last = b;
        } else if (after) {
            after->prev = b;
        }
        n->magic = 0;
    }
}

void free(void *ptr) {
    if (!ptr) {
        return;
    }
    Block *b = (Block *)ptr - 1;
    if (b->magic != HEAP_MAGIC_USED) {
        fatal(b->magic == HEAP_MAGIC_FREE ? "free: double free" : "free: pointer not from malloc");
    }
    b->magic = HEAP_MAGIC_FREE;
    merge_next(b);
    if (b->prev && b->prev->magic == HEAP_MAGIC_FREE) {
        merge_next(b->prev);
    }
}

void *calloc(size_t count, size_t size) {
    if (size != 0 && count > (size_t)-1 / size) {
        return NULL;
    }
    void *p = malloc(count * size);
    if (p) {
        memset(p, 0, count * size);
    }
    return p;
}

void *realloc(void *ptr, size_t request) {
    if (!ptr) {
        return malloc(request);
    }
    if (request == 0) {
        free(ptr);
        return NULL;
    }
    Block *b = (Block *)ptr - 1;
    if (b->magic != HEAP_MAGIC_USED) {
        fatal("realloc: pointer not from malloc");
    }
    size_t size = align_up(request);
    if (b->size >= size) {
        return ptr;
    }
    Block *n = block_next(b);
    if (n && n->magic == HEAP_MAGIC_FREE && b->size + sizeof(Block) + n->size >= size) {
        merge_next(b);
        split(b, size);
        return ptr;
    }
    void *fresh = malloc(request);
    if (!fresh) {
        return NULL;
    }
    memcpy(fresh, ptr, b->size);
    free(ptr);
    return fresh;
}

int32_t eden_alloc(int32_t size) {
    if (size < 0) {
        return 0;
    }
    return (int32_t)(uintptr_t)malloc((size_t)size);
}

void eden_free(int32_t ptr) {
    free((void *)(uintptr_t)ptr);
}

/* ------------------------------------------------------------------------ */
/* Memory and strings                                                        */
/* ------------------------------------------------------------------------ */

void *memset(void *dest, int value, size_t count) {
    unsigned char *d = (unsigned char *)dest;
    while (count--) {
        *d++ = (unsigned char)value;
    }
    return dest;
}

void *memcpy(void *dest, const void *src, size_t count) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    if ((((uintptr_t)d | (uintptr_t)s) & 3u) == 0) {
        while (count >= 4) {
            *(uint32_t *)d = *(const uint32_t *)s;
            d += 4;
            s += 4;
            count -= 4;
        }
    }
    while (count--) {
        *d++ = *s++;
    }
    return dest;
}

void *memmove(void *dest, const void *src, size_t count) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    if (d == s || count == 0) {
        return dest;
    }
    if (d < s || d >= s + count) {
        return memcpy(dest, src, count);
    }
    while (count--) {
        d[count] = s[count];
    }
    return dest;
}

int memcmp(const void *lhs, const void *rhs, size_t count) {
    const unsigned char *a = (const unsigned char *)lhs;
    const unsigned char *b = (const unsigned char *)rhs;
    for (size_t i = 0; i < count; i++) {
        if (a[i] != b[i]) {
            return a[i] < b[i] ? -1 : 1;
        }
    }
    return 0;
}

void *memchr(const void *src, int value, size_t count) {
    const unsigned char *s = (const unsigned char *)src;
    for (size_t i = 0; i < count; i++) {
        if (s[i] == (unsigned char)value) {
            return (void *)(s + i);
        }
    }
    return NULL;
}

size_t strlen(const char *src) {
    size_t n = 0;
    while (src[n]) {
        n++;
    }
    return n;
}

int strcmp(const char *lhs, const char *rhs) {
    while (*lhs && *lhs == *rhs) {
        lhs++;
        rhs++;
    }
    return (int)(unsigned char)*lhs - (int)(unsigned char)*rhs;
}

int strncmp(const char *lhs, const char *rhs, size_t count) {
    for (size_t i = 0; i < count; i++) {
        unsigned char a = (unsigned char)lhs[i];
        unsigned char b = (unsigned char)rhs[i];
        if (a != b || a == 0) {
            return (int)a - (int)b;
        }
    }
    return 0;
}

char *strcpy(char *dest, const char *src) {
    char *d = dest;
    while ((*d++ = *src++)) {
    }
    return dest;
}

char *strncpy(char *dest, const char *src, size_t count) {
    size_t i = 0;
    for (; i < count && src[i]; i++) {
        dest[i] = src[i];
    }
    for (; i < count; i++) {
        dest[i] = 0;
    }
    return dest;
}

char *strchr(const char *src, int ch) {
    for (;; src++) {
        if (*src == (char)ch) {
            return (char *)src;
        }
        if (!*src) {
            return NULL;
        }
    }
}

char *strrchr(const char *src, int ch) {
    const char *found = NULL;
    for (;; src++) {
        if (*src == (char)ch) {
            found = src;
        }
        if (!*src) {
            return (char *)found;
        }
    }
}

char *strdup(const char *src) {
    size_t n = strlen(src) + 1;
    char *d = (char *)malloc(n);
    if (d) {
        memcpy(d, src, n);
    }
    return d;
}

int abs(int value) {
    return value < 0 ? -value : value;
}

long labs(long value) {
    return value < 0 ? -value : value;
}

long strtol(const char *text, char **end, int base) {
    const char *s = text;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r' || *s == '\f' || *s == '\v') {
        s++;
    }
    int negative = 0;
    if (*s == '+' || *s == '-') {
        negative = *s == '-';
        s++;
    }
    if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
        base = 16;
    } else if (base == 0) {
        base = s[0] == '0' ? 8 : 10;
    }
    unsigned long value = 0;
    const char *digits = s;
    for (;; s++) {
        int d;
        if (*s >= '0' && *s <= '9') {
            d = *s - '0';
        } else if (*s >= 'a' && *s <= 'z') {
            d = *s - 'a' + 10;
        } else if (*s >= 'A' && *s <= 'Z') {
            d = *s - 'A' + 10;
        } else {
            break;
        }
        if (d >= base) {
            break;
        }
        value = value * (unsigned long)base + (unsigned long)d;
    }
    if (end) {
        *end = (char *)(s == digits ? text : s);
    }
    return negative ? -(long)value : (long)value;
}

int atoi(const char *text) {
    return (int)strtol(text, NULL, 10);
}

/* ------------------------------------------------------------------------ */
/* Formatting                                                                */
/* ------------------------------------------------------------------------ */

typedef struct Sink {
    char *buf;
    size_t cap;  /* bytes available including the NUL */
    size_t len;  /* characters produced (may exceed cap) */
} Sink;

static void put(Sink *s, char c) {
    if (s->len + 1 < s->cap) {
        s->buf[s->len] = c;
    }
    s->len++;
}

static void put_repeat(Sink *s, char c, int n) {
    while (n-- > 0) {
        put(s, c);
    }
}

static void put_number(Sink *s, unsigned long long v, int base, int upper, int negative, int plus, int space,
                       int width, int precision, int left, int zero, const char *prefix) {
    char digits[32];
    int n = 0;
    const char *set = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (v == 0 && precision != 0) {
        digits[n++] = '0';
    }
    while (v) {
        digits[n++] = set[v % (unsigned)base];
        v /= (unsigned)base;
    }
    int zeros = precision > n ? precision - n : 0;
    char sign = negative ? '-' : plus ? '+' : space ? ' ' : 0;
    int prefix_len = prefix ? (int)strlen(prefix) : 0;
    int body = n + zeros + (sign ? 1 : 0) + prefix_len;
    int pad = width > body ? width - body : 0;
    if (zero && precision < 0 && !left) {
        zeros += pad;
        pad = 0;
    }
    if (!left) {
        put_repeat(s, ' ', pad);
    }
    if (sign) {
        put(s, sign);
    }
    for (int i = 0; i < prefix_len; i++) {
        put(s, prefix[i]);
    }
    put_repeat(s, '0', zeros);
    while (n) {
        put(s, digits[--n]);
    }
    if (left) {
        put_repeat(s, ' ', pad);
    }
}

static void put_double(Sink *s, double v, int precision, int width, int left, int zero, int plus, int space) {
    char text[64];
    int n = 0;
    if (precision < 0) {
        precision = 6;
    }
    if (precision > 9) {
        precision = 9;
    }
    int negative = v < 0.0 || (v == 0.0 && 1.0 / v < 0.0);
    if (v != v) {
        text[n++] = 'n';
        text[n++] = 'a';
        text[n++] = 'n';
        negative = 0;
    } else {
        if (negative) {
            v = -v;
        }
        if (v > 1e18) {
            text[n++] = 'i';
            text[n++] = 'n';
            text[n++] = 'f';
        } else {
            double scale = 1.0;
            for (int i = 0; i < precision; i++) {
                scale *= 10.0;
            }
            unsigned long long whole = (unsigned long long)v;
            double frac_part = (v - (double)whole) * scale + 0.5;
            unsigned long long frac = (unsigned long long)frac_part;
            if ((double)frac >= scale) {
                whole += 1;
                frac -= (unsigned long long)scale;
            }
            char w[24];
            int wn = 0;
            do {
                w[wn++] = (char)('0' + whole % 10u);
                whole /= 10u;
            } while (whole);
            while (wn) {
                text[n++] = w[--wn];
            }
            if (precision > 0) {
                text[n++] = '.';
                char f[16];
                for (int i = precision - 1; i >= 0; i--) {
                    f[i] = (char)('0' + frac % 10u);
                    frac /= 10u;
                }
                for (int i = 0; i < precision; i++) {
                    text[n++] = f[i];
                }
            }
        }
    }
    char sign = negative ? '-' : plus ? '+' : space ? ' ' : 0;
    int body = n + (sign ? 1 : 0);
    int pad = width > body ? width - body : 0;
    int zeros = 0;
    if (zero && !left && text[0] >= '0' && text[0] <= '9') {
        zeros = pad;
        pad = 0;
    }
    if (!left) {
        put_repeat(s, ' ', pad);
    }
    if (sign) {
        put(s, sign);
    }
    put_repeat(s, '0', zeros);
    for (int i = 0; i < n; i++) {
        put(s, text[i]);
    }
    if (left) {
        put_repeat(s, ' ', pad);
    }
}

int vsnprintf(char *buffer, size_t size, const char *f, va_list args) {
    Sink s = {buffer, size, 0};
    while (*f) {
        if (*f != '%') {
            put(&s, *f++);
            continue;
        }
        f++;
        int left = 0, zero = 0, plus = 0, space = 0, alt = 0;
        for (;; f++) {
            if (*f == '-') left = 1;
            else if (*f == '0') zero = 1;
            else if (*f == '+') plus = 1;
            else if (*f == ' ') space = 1;
            else if (*f == '#') alt = 1;
            else break;
        }
        int width = 0;
        if (*f == '*') {
            width = va_arg(args, int);
            if (width < 0) {
                left = 1;
                width = -width;
            }
            f++;
        } else {
            while (*f >= '0' && *f <= '9') {
                width = width * 10 + (*f++ - '0');
            }
        }
        int precision = -1;
        if (*f == '.') {
            f++;
            precision = 0;
            if (*f == '*') {
                precision = va_arg(args, int);
                f++;
            } else {
                while (*f >= '0' && *f <= '9') {
                    precision = precision * 10 + (*f++ - '0');
                }
            }
        }
        int length = 0; /* 0 int, 1 long, 2 long long, -1 short, -2 char, 3 size_t/ptrdiff/intmax */
        if (*f == 'h') {
            f++;
            length = -1;
            if (*f == 'h') {
                f++;
                length = -2;
            }
        } else if (*f == 'l') {
            f++;
            length = 1;
            if (*f == 'l') {
                f++;
                length = 2;
            }
        } else if (*f == 'z' || *f == 't') {
            f++;
            length = 1; /* size_t and ptrdiff_t are long on wasm32 */
        } else if (*f == 'j') {
            f++;
            length = 2;
        }
        char c = *f ? *f++ : 0;
        switch (c) {
            case 'd':
            case 'i': {
                long long v = length >= 2 ? va_arg(args, long long) : length == 1 ? va_arg(args, long) : va_arg(args, int);
                if (length == -1) v = (short)v;
                if (length == -2) v = (signed char)v;
                unsigned long long mag = v < 0 ? (unsigned long long)(-(v + 1)) + 1u : (unsigned long long)v;
                put_number(&s, mag, 10, 0, v < 0, plus, space, width, precision, left, zero, NULL);
                break;
            }
            case 'u':
            case 'o':
            case 'x':
            case 'X': {
                unsigned long long v = length >= 2 ? va_arg(args, unsigned long long)
                                     : length == 1 ? va_arg(args, unsigned long)
                                                   : va_arg(args, unsigned int);
                if (length == -1) v = (unsigned short)v;
                if (length == -2) v = (unsigned char)v;
                int base = c == 'u' ? 10 : c == 'o' ? 8 : 16;
                const char *prefix = NULL;
                if (alt && v != 0) {
                    prefix = c == 'o' ? "0" : c == 'x' ? "0x" : c == 'X' ? "0X" : NULL;
                }
                put_number(&s, v, base, c == 'X', 0, 0, 0, width, precision, left, zero, prefix);
                break;
            }
            case 'p': {
                uintptr_t v = (uintptr_t)va_arg(args, void *);
                put_number(&s, v, 16, 0, 0, 0, 0, width, -1, left, 0, "0x");
                break;
            }
            case 'c': {
                int pad = width > 1 ? width - 1 : 0;
                if (!left) put_repeat(&s, ' ', pad);
                put(&s, (char)va_arg(args, int));
                if (left) put_repeat(&s, ' ', pad);
                break;
            }
            case 's': {
                const char *str = va_arg(args, const char *);
                if (!str) {
                    str = "(null)";
                }
                int n = 0;
                while (str[n] && (precision < 0 || n < precision)) {
                    n++;
                }
                int pad = width > n ? width - n : 0;
                if (!left) put_repeat(&s, ' ', pad);
                for (int i = 0; i < n; i++) {
                    put(&s, str[i]);
                }
                if (left) put_repeat(&s, ' ', pad);
                break;
            }
            case 'f':
            case 'F':
                put_double(&s, va_arg(args, double), precision, width, left, zero, plus, space);
                break;
            case '%':
                put(&s, '%');
                break;
            case 0:
                break;
            default:
                /* an unsupported conversion is printed as written */
                put(&s, '%');
                put(&s, c);
                break;
        }
    }
    if (s.cap > 0) {
        s.buf[s.len < s.cap ? s.len : s.cap - 1] = 0;
    }
    return (int)s.len;
}

int snprintf(char *buffer, size_t size, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int n = vsnprintf(buffer, size, format, args);
    va_end(args);
    return n;
}

/* ------------------------------------------------------------------------ */
/* Files                                                                     */
/* ------------------------------------------------------------------------ */

#define LINE_CAP 1024
#define NAME_CAP 256

struct FILE {
    int kind; /* KIND_* below */
    int level;
    char line[LINE_CAP];
    size_t line_len;
    char name[NAME_CAP];
    long pos;
    long size;
    unsigned char *data; /* KIND_WRITE: the blob being written */
    size_t cap;
    int dirty;
};

static FILE s_stdout = {1, EDEN_CORE_LOG_INFO, {0}, 0, {0}, 0, 0, NULL, 0, 0};
static FILE s_stderr = {1, EDEN_CORE_LOG_WARN, {0}, 0, {0}, 0, 0, NULL, 0, 0};
FILE *stdout = &s_stdout;
FILE *stderr = &s_stderr;

static void log_flush(FILE *f) {
    if (f->line_len) {
        eden_core_log(f->level, f->line, (int32_t)f->line_len);
        f->line_len = 0;
    }
}

static void log_write(FILE *f, const char *data, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (data[i] == '\n') {
            log_flush(f);
        } else {
            if (f->line_len == LINE_CAP) {
                log_flush(f);
            }
            f->line[f->line_len++] = data[i];
        }
    }
}

int vfprintf(FILE *stream, const char *format, va_list args) {
    char text[LINE_CAP];
    va_list copy;
    va_copy(copy, args);
    int n = vsnprintf(text, sizeof text, format, copy);
    va_end(copy);
    if (n < 0) {
        return n;
    }
    if ((size_t)n >= sizeof text) {
        char *big = (char *)malloc((size_t)n + 1);
        if (!big) {
            return -1;
        }
        vsnprintf(big, (size_t)n + 1, format, args);
        fwrite(big, 1, (size_t)n, stream);
        free(big);
        return n;
    }
    fwrite(text, 1, (size_t)n, stream);
    return n;
}

int fprintf(FILE *stream, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int n = vfprintf(stream, format, args);
    va_end(args);
    return n;
}

int printf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    int n = vfprintf(stdout, format, args);
    va_end(args);
    return n;
}

int fputs(const char *text, FILE *stream) {
    size_t n = strlen(text);
    return fwrite(text, 1, n, stream) == n ? 0 : EOF;
}

int puts(const char *text) {
    if (fputs(text, stdout) == EOF) {
        return EOF;
    }
    return fputs("\n", stdout);
}

int putchar(int ch) {
    char c = (char)ch;
    fwrite(&c, 1, 1, stdout);
    return (unsigned char)c;
}

/* kinds: KIND_LOG (stdout/stderr), KIND_ASSET and KIND_BLOB (read in place
 * through eden_asset / eden_storage), KIND_WRITE (a buffer that becomes an
 * eden_storage blob on fflush / fclose) */
#define KIND_LOG 1
#define KIND_ASSET 2
#define KIND_BLOB 3
#define KIND_WRITE 4

static FILE *new_file(int kind, const char *filename, size_t n) {
    FILE *f = (FILE *)calloc(1, sizeof(FILE));
    if (!f) {
        return NULL;
    }
    f->kind = kind;
    memcpy(f->name, filename, n + 1);
    return f;
}

/* grows a write buffer to hold `need` bytes; 0 on failure */
static int reserve_buffer(FILE *f, size_t need) {
    if (need <= f->cap) {
        return 1;
    }
    size_t cap = f->cap ? f->cap : 256;
    while (cap < need) {
        cap *= 2;
    }
    unsigned char *grown = (unsigned char *)realloc(f->data, cap);
    if (!grown) {
        return 0;
    }
    f->data = grown;
    f->cap = cap;
    return 1;
}

FILE *fopen(const char *filename, const char *mode) {
    if (!filename || !mode || strchr(mode, '+')) {
        return NULL;
    }
    size_t n = strlen(filename);
    if (n == 0 || n > EDEN_STORAGE_MAX_NAME || n >= NAME_CAP) {
        return NULL;
    }
    if (mode[0] == 'r') {
        int32_t size = eden_storage_size_z(filename);
        int kind = KIND_BLOB;
        if (size < 0) {
            size = eden_asset_size_z(filename);
            kind = KIND_ASSET;
        }
        if (size < 0) {
            return NULL;
        }
        FILE *f = new_file(kind, filename, n);
        if (f) {
            f->size = size;
        }
        return f;
    }
    if (mode[0] != 'w' && mode[0] != 'a') {
        return NULL;
    }
    FILE *f = new_file(KIND_WRITE, filename, n);
    if (!f) {
        return NULL;
    }
    if (mode[0] == 'a') {
        /* start from the blob, or from the asset of the same name */
        int from_storage = 1;
        int32_t size = eden_storage_size_z(filename);
        if (size < 0) {
            size = eden_asset_size_z(filename);
            from_storage = 0;
        }
        if (size > 0) {
            if (!reserve_buffer(f, (size_t)size)) {
                free(f);
                return NULL;
            }
            int32_t got = from_storage ? eden_storage_read_z(filename, 0, f->data, size)
                                       : eden_asset_read_z(filename, 0, f->data, size);
            if (got != size) {
                free(f->data);
                free(f);
                return NULL;
            }
            f->size = size;
            f->pos = size;
        }
    }
    f->dirty = 1; /* "w" creates the blob even when nothing is written */
    return f;
}

static int flush_write(FILE *f) {
    if (!f->dirty) {
        return 0;
    }
    if (eden_storage_write_z(f->name, f->data, (int32_t)f->size) != EDEN_STORAGE_OK) {
        return EOF;
    }
    f->dirty = 0;
    return 0;
}

int fflush(FILE *stream) {
    if (!stream) {
        log_flush(stdout);
        log_flush(stderr);
        return 0;
    }
    if (stream->kind == KIND_LOG) {
        log_flush(stream);
    } else if (stream->kind == KIND_WRITE) {
        return flush_write(stream);
    }
    return 0;
}

int fclose(FILE *stream) {
    if (!stream) {
        return EOF;
    }
    if (stream->kind == KIND_LOG) {
        log_flush(stream);
        return 0;
    }
    int r = 0;
    if (stream->kind == KIND_WRITE) {
        r = flush_write(stream);
        free(stream->data);
    }
    free(stream);
    return r;
}

size_t fread(void *buffer, size_t size, size_t count, FILE *stream) {
    if (!stream || size == 0 || count == 0 || count > (size_t)-1 / size) {
        return 0;
    }
    if (stream->kind != KIND_ASSET && stream->kind != KIND_BLOB) {
        return 0;
    }
    size_t want = size * count;
    long left = stream->size - stream->pos;
    if (left <= 0) {
        return 0;
    }
    if (want > (size_t)left) {
        want = (size_t)left;
    }
    int32_t got = stream->kind == KIND_BLOB
                      ? eden_storage_read_z(stream->name, (int32_t)stream->pos, buffer, (int32_t)want)
                      : eden_asset_read_z(stream->name, (int32_t)stream->pos, buffer, (int32_t)want);
    if (got <= 0) {
        return 0;
    }
    stream->pos += got;
    return (size_t)got / size;
}

size_t fwrite(const void *buffer, size_t size, size_t count, FILE *stream) {
    if (!stream || size == 0 || count > (size_t)-1 / size) {
        return 0;
    }
    if (stream->kind == KIND_LOG) {
        log_write(stream, (const char *)buffer, size * count);
        return count;
    }
    if (stream->kind != KIND_WRITE) {
        return 0;
    }
    size_t n = size * count;
    size_t end = (size_t)stream->pos + n;
    if (end > (size_t)EDEN_STORAGE_MAX_TOTAL_BYTES || !reserve_buffer(stream, end)) {
        return 0;
    }
    memcpy(stream->data + stream->pos, buffer, n);
    stream->pos = (long)end;
    if ((long)end > stream->size) {
        stream->size = (long)end;
    }
    stream->dirty = 1;
    return count;
}

int fseek(FILE *stream, long offset, int origin) {
    if (!stream || stream->kind == KIND_LOG) {
        return -1;
    }
    long base = origin == SEEK_SET ? 0 : origin == SEEK_CUR ? stream->pos : origin == SEEK_END ? stream->size : -1;
    if (base < 0 || base + offset < 0 || base + offset > stream->size) {
        return -1;
    }
    stream->pos = base + offset;
    return 0;
}

long ftell(FILE *stream) {
    if (!stream || stream->kind == KIND_LOG) {
        return -1;
    }
    return stream->pos;
}

int remove(const char *filename) {
    if (!filename) {
        return -1;
    }
    return eden_storage_remove_z(filename) == EDEN_STORAGE_OK ? 0 : -1;
}

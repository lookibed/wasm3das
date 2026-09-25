/* The freestanding libc of Eden ABI guests: a failed assert aborts the guest
 * through eden_core.abort with the expression and its location. Define
 * NDEBUG to compile asserts out, as with any libc. */
#ifndef EDEN_LIBC_ASSERT_H
#define EDEN_LIBC_ASSERT_H

void eden_libc_assert_fail(const char *expr, const char *file, int line) __attribute__((noreturn));

#ifdef NDEBUG
#define assert(condition) ((void)0)
#else
#define assert(condition) ((condition) ? (void)0 : eden_libc_assert_fail(#condition, __FILE__, __LINE__))
#endif

#endif

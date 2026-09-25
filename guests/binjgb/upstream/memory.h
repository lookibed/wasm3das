/*
 * Copyright (C) 2017 Ben Smith
 *
 * This software may be modified and distributed under the terms
 * of the MIT license.  See the LICENSE file for details.
 */
/*
 * binjgb's src/memory.h without its MEMORY_TRACKING branch: the allocation
 * wrappers are the libc functions. The Spider copy of the sources omits this
 * file (its include/memory.h is only <string.h>), which leaves xmalloc and
 * friends implicitly declared; with it they are declared properly.
 */
#ifndef BINJGB_MEMORY_H_
#define BINJGB_MEMORY_H_

#include <stdlib.h>
#include <string.h>

#define xmalloc malloc
#define xfree free
#define xcalloc calloc
#define xrealloc realloc

#endif /* BINJGB_MEMORY_H_ */

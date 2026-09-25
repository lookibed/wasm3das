options gen2
options indenting = 4
// Eden: the upstream `options never_inline = true` (code pages are written by
// the compiler once per wasm function, so inlining costs startup only) is
// dropped: the option is untested in the editor (DESIGN.md section 1) and the
// interpreter is the only tier of the Eden port.

module m3_code shared public

require modules/wasm3das/source/m3_core public   // Eden: project-root-relative path (upstream: ./m3_core.das)
require modules/wasm3das/source/m3_types         // Eden: project-root-relative path (upstream: ./m3_types.das)


/*
    m3_code.h / m3_code.c -> m3_code.das

    Pure gen2 Daslang port of wasm3 code-page storage.

    Memory adaptation (upstream port):

    C declares M3CodePage as a header followed by a one-element/flexible code
    tail. NewCodePage allocates a single raw block whose aligned size determines
    the real number of code_t slots. Daslang dynamic arrays were deliberately
    NOT used by the upstream port because that would change ownership, layout,
    list semantics, and the meaning of GetPageStartPC/GetPagePC.

    Instead the upstream M3CodePage contained only the fixed header in the type
    system, the inline code slots lived immediately after that header in the
    same raw block, exactly as in C, and GetPageStartPC performed the one
    documented pointer offset needed to reach this tail. Allocation/free went
    through m3_core's raw m3_Malloc_Impl/m3_Free_Impl helpers; no C interop,
    WASI, smart pointers, or reference counting were introduced.

    d_m3RecordBacktraces is currently disabled, matching wasm3's default
    configuration. Therefore the conditional mapping pointer and mapping-page
    storage are intentionally absent until the backtrace layer is ported.

    Eden: deviations from the upstream port (.upstream/source/m3_code.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md). The sandbox has no
    raw pointers, so a code page is a region of one array and a page a handle
    (DESIGN sections 4.1 and 4.4, the decisions fixed by m3_types):
      - requires are Eden-project-root relative (DESIGN section 6); m3_core
        stays a public re-export.
      - the page arena is rt.codePages : array<M3CodePage>; IM3CodePage is a
        handle into it (-1 = NULL). A page's words are a contiguous region
        of rt.code : array<u64>: page.code is the index of its first word,
        page.info.numLines its capacity in words, page.info.lineIndex the
        next free line (the C names). Every function therefore takes the
        runtime first (`var` when it writes a page or a word), then the C
        parameters in C order; the C `IM3CodePage *` list heads are `int&`
        (rt.pagesOpen, rt.pagesFull, rt.pagesReleased or a local).
      - NewCodePage keeps C's u32 size arithmetic (header + words, rounded
        up to d_m3CodePageAlignSize, the overflow guards of the upstream
        port) to get C's numLines for a request; the header size is C's
        sizeof (M3CodePageHeader) (M3_SIZEOF_CODE_PAGE_HEADER: the pointer
        size plus four u32, an allocation-layout figure only, since the Eden
        header stores `next` as an int handle); then it appends numLines zero words to
        rt.code (C: calloc) and one slot to rt.codePages through
        m3_Realloc_Impl (never `resize` on an array of structs, DESIGN
        section 6). Allocation cannot fail observably, so the C null test
        after m3_Malloc has no counterpart; the guards still return -1.
      - a code word is a u64 (code_t): an operation by its index in the op
        table, an immediate by value, a pc or a handle as u64(int) (DESIGN
        section 4.4). EmitWord (C: the macro casting any value to void *)
        takes the u64 word; EmitWord32 writes u64(i_word) (C copies four
        bytes into the slot and leaves the rest as allocated, zero); EmitWord64
        writes the word into one line, as C does when sizeof(code_t) is 8,
        keeping the upstream slot computation from sizeof(code_t).
      - GetPageStartPC / GetPagePC return absolute pc_t indices into rt.code
        (page.code, page.code + lineIndex); pointer arithmetic on a pc is
        index arithmetic. GetPagePC(-1) is -1.
      - FreeCodePages unlinks every page of the list and resets its slot
        (header to the defaults, code to -1: a freed page has no words and no
        successor), leaving the slot in rt.codePages and the words in rt.code:
        handles and pcs already handed out stay stable, as DESIGN section 4.1
        says a runtime is freed by clearing its arrays. m3_Free has no other
        counterpart.
      - the page pool of m3_env.c (hosted here, see the note below) is the
        runtime's: Environment_AcquireCodePage and Environment_ReleaseCodePages
        take the runtime and use rt.pagesReleased (C: the environment's
        field; the pool moved into the runtime, DESIGN section 4.1). A
        released page is reused with lineIndex reset, as in C; its old words
        in rt.code are overwritten by the next emits.
      - d_m3Assert stays at every C site; the m3log and DEBUG-only branches
        are compiled out as upstream.
      - the upstream `options never_inline` is dropped (see the options).
    Everything else (function names, C order, control flow, the list
    algorithms, the free-lines threshold, the counters) is unchanged.
*/


// ============================================================================
// 1. NewCodePage
// ============================================================================



let private m3_u32_max : u64 = 0xfffffffful

/* C: sizeof (M3CodePageHeader) — the `next` pointer and four u32 (lineIndex,
   numLines, sequence, usageCount), 24 bytes on a 64-bit target. */
// Eden: the Eden header stores `next` as an int handle, so `typeinfo sizeof`
// of it (20) is not C's size; the C size is what the page arithmetic of
// NewCodePage rounds with, so a request gets C's numLines.
let public M3_SIZEOF_CODE_PAGE_HEADER : u32 = M3_SIZEOF_PTR + 4u * 4u


def public NewCodePage(
                       var i_runtime : M3Runtime;
                       i_minNumLines : u32
                       ) : IM3CodePage {
    let codeSize = u64(typeinfo sizeof(type<code_t>))
    let headerSize = u64(M3_SIZEOF_CODE_PAGE_HEADER)   // Eden: C's sizeof (M3CodePageHeader), see the constant
    let alignSize = u64(d_m3CodePageAlignSize)

    // C first guards sizeof(code_t) * i_minNumLines against UINT_MAX.
    if (codeSize == 0ul || u64(i_minNumLines) > m3_u32_max / codeSize) {
        return -1
    }

    let codeBytes = codeSize * u64(i_minNumLines)

    // Preserve the C u32 page-size domain while making addition overflow
    // explicit instead of relying on unsigned wraparound.
    if (headerSize > m3_u32_max || codeBytes > m3_u32_max - headerSize) {
        return -1
    }

    let pageSizeUnaligned = headerSize + codeBytes

    // C alignment: (size + align - 1) & ~(align - 1). Guard the addition
    // before performing it so an impossible page returns null deterministically.
    let alignMask = alignSize - 1ul
    if (pageSizeUnaligned > m3_u32_max - alignMask) {
        return -1
    }

    let pageSize = (pageSizeUnaligned + alignMask) & ~alignMask
    if (pageSize == 0ul || pageSize > m3_u32_max) {
        return -1
    }

    // C: page = m3_Malloc ("M3CodePage", pageSize)
    // Eden: the page is a new slot of the arena and its words a new region
    // at the end of rt.code; the slot's default is C's zero fill
    // (lineIndex, usageCount 0, next null)
    let numPages = length(i_runtime.codePages)
    m3_Realloc_Impl(i_runtime.codePages, numPages + 1, numPages)
    let page : IM3CodePage = numPages

    i_runtime.newCodePageSequence++
    i_runtime.codePages[page].info.sequence = i_runtime.newCodePageSequence
    i_runtime.codePages[page].info.numLines = u32((pageSize - headerSize) / codeSize)

    // Eden: the words of the page, zero as calloc's (C: the tail of the block)
    i_runtime.codePages[page].code = length(i_runtime.code)
    resize(i_runtime.code, length(i_runtime.code) + int(i_runtime.codePages[page].info.numLines))

    // C: m3log (runtime, "new page: ...") — compiled out under the active configuration.
    return page
}


// ============================================================================
// 2. FreeCodePages
// ============================================================================


def public FreeCodePages(var i_runtime : M3Runtime; var io_list : IM3CodePage&) {
    var page = io_list

    while (page != -1) {
        // C: m3log (code, "free page: ...") — compiled out under the active configuration.

        let next = i_runtime.codePages[page].info.next
        // C: m3_Free (page). Eden: the slot stays in the arena and the words
        // in rt.code (handles and pcs stay stable); the page is unlinked and
        // reset so a stale handle reads as an empty page without words
        i_runtime.codePages[page].info = M3CodePageHeader()
        i_runtime.codePages[page].code = -1
        page = next
    }

    io_list = -1
}


// ============================================================================
// 3. NumFreeLines
// ============================================================================


def public NumFreeLines(i_runtime : M3Runtime; i_page : IM3CodePage) : u32 {
    d_m3Assert(
        i_runtime.codePages[i_page].info.lineIndex <= i_runtime.codePages[i_page].info.numLines,
        "NumFreeLines: lineIndex exceeds numLines"
    )

    return i_runtime.codePages[i_page].info.numLines - i_runtime.codePages[i_page].info.lineIndex
}


// ============================================================================
// 4. EmitWord_impl
// ============================================================================


/* C m3_code.h: #define EmitWord(page, val) EmitWord_impl((page), (const void *)(val)) */
// Eden: the word is a u64 (an op index, an immediate, a pc or a handle as
// u64(int), DESIGN.md 4.4); the caller converts, as C's cast to void * did.
def public EmitWord(var i_runtime : M3Runtime; i_page : IM3CodePage; i_word : u64) {
    EmitWord_impl(i_runtime, i_page, i_word)
}


def public EmitWord_impl(var i_runtime : M3Runtime; i_page : IM3CodePage; i_word : code_t) {
    d_m3Assert(
        i_runtime.codePages[i_page].info.lineIndex + 1u <= i_runtime.codePages[i_page].info.numLines,
        "EmitWord_impl: code page overflow"
    )

    // C: i_page->code [i_page->info.lineIndex++] = i_word
    let code = GetPageStartPC(i_runtime, i_page)
    i_runtime.code[code + int(i_runtime.codePages[i_page].info.lineIndex)] = i_word
    i_runtime.codePages[i_page].info.lineIndex++
}


// ============================================================================
// 5. EmitWord32
// ============================================================================


def public EmitWord32(var i_runtime : M3Runtime; i_page : IM3CodePage; i_word : u32) {
    d_m3Assert(
        i_runtime.codePages[i_page].info.lineIndex + 1u <= i_runtime.codePages[i_page].info.numLines,
        "EmitWord32: code page overflow"
    )

    // C: memcpy (& i_page->code[i_page->info.lineIndex++], & i_word, sizeof(i_word))
    // Eden: the low 32 bits of the word; the rest is zero, as the allocated slot was
    let dst = GetPagePC(i_runtime, i_page)
    i_runtime.code[dst] = u64(i_word)
    i_runtime.codePages[i_page].info.lineIndex++
}


// ============================================================================
// 6. EmitWord64
// ============================================================================


def public EmitWord64(var i_runtime : M3Runtime; i_page : IM3CodePage; i_word : u64) {
    // C: M3_SIZEOF_PTR == 4 takes two lines; Eden: code_t is a u64, one line
    let codeSize = u32(typeinfo sizeof(type<code_t>))
    let slots = codeSize == 4u ? 2u : 1u

    d_m3Assert(
        i_runtime.codePages[i_page].info.lineIndex + slots <= i_runtime.codePages[i_page].info.numLines,
        "EmitWord64: code page overflow"
    )

    // C: memcpy (& i_page->code[i_page->info.lineIndex], & i_word, sizeof(i_word))
    let dst = GetPagePC(i_runtime, i_page)
    i_runtime.code[dst] = i_word
    i_runtime.codePages[i_page].info.lineIndex += slots
}


// ============================================================================
// 7. GetPageStartPC
// ============================================================================


def public GetPageStartPC(i_runtime : M3Runtime; i_page : IM3CodePage) : pc_t {
    // C: & i_page->code [0]; Eden: the index of the page's first word in rt.code
    return i_runtime.codePages[i_page].code
}


// ============================================================================
// 8. GetPagePC
// ============================================================================


def public GetPagePC(i_runtime : M3Runtime; i_page : IM3CodePage) : pc_t {
    if (i_page == -1) {
        return -1
    }

    // C: & i_page->code [i_page->info.lineIndex]
    var pc = GetPageStartPC(i_runtime, i_page)
    pc = pc + int(i_runtime.codePages[i_page].info.lineIndex)
    return pc
}


// ============================================================================
// 9. PushCodePage
// ============================================================================


def public PushCodePage(
                        var i_runtime : M3Runtime;
                        var io_list : IM3CodePage&;
                        i_codePage : IM3CodePage
                        ) {
    let next = io_list
    i_runtime.codePages[i_codePage].info.next = next
    io_list = i_codePage
}


// ============================================================================
// 10. PopCodePage
// ============================================================================


def public PopCodePage(var i_runtime : M3Runtime; var io_list : IM3CodePage&) : IM3CodePage {
    let page = io_list
    let next = i_runtime.codePages[page].info.next
    io_list = next
    i_runtime.codePages[page].info.next = -1

    return page
}


// ============================================================================
// 11. FindCodePageEnd
// ============================================================================


def public FindCodePageEnd(
                           i_runtime : M3Runtime;
                           i_list : IM3CodePage;
                           var o_end : IM3CodePage&
                           ) : u32 {
    var numPages = 0u
    var list = i_list
    o_end = -1
    while (list != -1) {
        o_end = list
        ++numPages
        list = i_runtime.codePages[list].info.next
    }

    return numPages
}


// ============================================================================
// 12. CountCodePages
// ============================================================================


def public CountCodePages(i_runtime : M3Runtime; i_list : IM3CodePage) : u32 {
    var unused : IM3CodePage = -1
    return FindCodePageEnd(i_runtime, i_list, unused)
}


// ============================================================================
// 13. GetEndCodePage
// ============================================================================


def public GetEndCodePage(i_runtime : M3Runtime; i_list : IM3CodePage) : IM3CodePage {
    var end : IM3CodePage = -1
    FindCodePageEnd(i_runtime, i_list, end)

    return end
}


/*
    Backtrace mapping deliberately deferred:

        EmitMappingEntry
        ContainsPC
        MapPCToOffset

    M3CodeMapEntry / M3CodeMappingPage will be activated together with the
    backtrace layer so this module does not carry dead ownership state today.

    DEBUG dump_code_page is also intentionally omitted per assignment.
*/


// ============================================================================
// Code-page pool (ported from m3_env.c)
// ============================================================================


/*
    Deviation note: C keeps the page-pool functions in m3_env.c. They are
    hosted in m3_code.das because the Daslang module graph is acyclic: the
    compiler layer below the environment needs the pool, while m3_env.das
    itself requires m3_compile.das. The functions operate purely on the
    M3Runtime page fields and m3_code primitives; bodies follow the C
    source, with m3log and DEBUG-only branches compiled out under the active
    configuration.

    Eden: the two Environment_* functions take the runtime, whose
    pagesReleased field is C's environment->pagesReleased (DESIGN.md 4.1).
*/


/* C m3_env.c: IM3CodePage RemoveCodePageOfCapacity (M3CodePage ** io_list, u32 i_minimumLineCount) */
def public RemoveCodePageOfCapacity(var i_runtime : M3Runtime; var io_list : IM3CodePage&; i_minimumLineCount : u32) : IM3CodePage {
    var prev : IM3CodePage = -1
    var page = io_list

    while (page != -1) {
        if (NumFreeLines(i_runtime, page) >= i_minimumLineCount) {
            d_m3Assert(i_runtime.codePages[page].info.usageCount == 0u)
            let next = i_runtime.codePages[page].info.next
            if (prev != -1) {
                i_runtime.codePages[prev].info.next = next    // mid-list
            } else {
                io_list = next                                // front of list
            }
            break
        }

        prev = page
        page = i_runtime.codePages[page].info.next
    }

    return page
}


/* C m3_env.c: IM3CodePage Environment_AcquireCodePage (IM3Environment i_environment, u32 i_minimumLineCount) */
// Eden: takes the runtime; the released pool is rt.pagesReleased
def public Environment_AcquireCodePage(var i_runtime : M3Runtime; i_minimumLineCount : u32) : IM3CodePage {
    return RemoveCodePageOfCapacity(i_runtime, i_runtime.pagesReleased, i_minimumLineCount)
}


/* C m3_env.c: void Environment_ReleaseCodePages (IM3Environment i_environment, IM3CodePage i_codePageList) */
// Eden: takes the runtime; the released pool is rt.pagesReleased
def public Environment_ReleaseCodePages(var i_runtime : M3Runtime; i_codePageList : IM3CodePage) {
    var end = i_codePageList

    while (end != -1) {
        i_runtime.codePages[end].info.lineIndex = 0u    // reset page
        // d_m3RecordBacktraces == false: the C mapping reset is compiled out.

        let next = i_runtime.codePages[end].info.next
        if (next == -1) {
            break
        }

        end = next
    }

    if (end != -1) {
        i_runtime.codePages[end].info.next = i_runtime.pagesReleased
        i_runtime.pagesReleased = i_codePageList
    }
}


/* C m3_env.c: void ReleaseCodePageNoTrack (IM3Runtime i_runtime, IM3CodePage i_codePage) */
def public ReleaseCodePageNoTrack(var i_runtime : M3Runtime; i_codePage : IM3CodePage) {
    if (i_codePage != -1) {
        let pageFull = NumFreeLines(i_runtime, i_codePage) < d_m3CodePageFreeLinesThreshold

        if (pageFull) {
            PushCodePage(i_runtime, i_runtime.pagesFull, i_codePage)
        } else {
            PushCodePage(i_runtime, i_runtime.pagesOpen, i_codePage)
        }

        // C: m3log (emit, ...) — compiled out under the active configuration.
    }
}


/* C m3_env.c: IM3CodePage AcquireCodePageWithCapacity (IM3Runtime i_runtime, u32 i_minLineCount) */
def public AcquireCodePageWithCapacity(var i_runtime : M3Runtime; i_minLineCount : u32) : IM3CodePage {
    var page = RemoveCodePageOfCapacity(i_runtime, i_runtime.pagesOpen, i_minLineCount)

    if (page == -1) {
        page = Environment_AcquireCodePage(i_runtime, i_minLineCount)

        if (page == -1) {
            page = NewCodePage(i_runtime, i_minLineCount)
        }

        if (page != -1) {
            i_runtime.numCodePages++
        }
    }

    if (page != -1) {
        // C: m3log (emit, ...) — compiled out under the active configuration.
        i_runtime.numActiveCodePages++
    }

    return page
}


/* C m3_env.c: IM3CodePage AcquireCodePage (IM3Runtime i_runtime) */
def public AcquireCodePage(var i_runtime : M3Runtime) : IM3CodePage {
    return AcquireCodePageWithCapacity(i_runtime, d_m3CodePageFreeLinesThreshold)
}


/* C m3_env.c: void ReleaseCodePage (IM3Runtime i_runtime, IM3CodePage i_codePage) */
def public ReleaseCodePage(var i_runtime : M3Runtime; i_codePage : IM3CodePage) {
    if (i_codePage != -1) {
        ReleaseCodePageNoTrack(i_runtime, i_codePage)
        i_runtime.numActiveCodePages--

        // C: DEBUG-only page accounting and m3log are compiled out.
    }
}

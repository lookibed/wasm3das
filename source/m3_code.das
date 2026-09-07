options gen2
options indenting = 4

module m3_code shared public

require ./m3_core.das public
require ./m3_types.das


/*
    m3_code.h / m3_code.c -> m3_code.das

    Pure gen2 Daslang port of wasm3 code-page storage.

    Memory adaptation:

    C declares M3CodePage as a header followed by a one-element/flexible code
    tail. NewCodePage allocates a single raw block whose aligned size determines
    the real number of code_t slots. Daslang dynamic arrays are deliberately NOT
    used here because that would change ownership, layout, list semantics, and
    the meaning of GetPageStartPC/GetPagePC.

    Instead M3CodePage contains only the fixed header in the type system. The
    inline code slots live immediately after that header in the same raw block,
    exactly as in C. GetPageStartPC performs the one documented unsafe pointer
    offset needed to reach this tail. Allocation/free go through m3_core's raw
    m3_Malloc_Impl/m3_Free_Impl helpers; no C interop, WASI, smart pointers, or
    reference counting are introduced.

    d_m3RecordBacktraces is currently disabled, matching wasm3's default
    configuration. Therefore the conditional mapping pointer and mapping-page
    storage are intentionally absent until the backtrace layer is ported.
*/


// ============================================================================
// 1. NewCodePage
// ============================================================================



let private m3_u32_max : u64 = 0xfffffffful


def public NewCodePage(
                       var i_runtime : IM3Runtime;
                       i_minNumLines : u32
                       ) : IM3CodePage {
    let codeSize = u64(typeinfo sizeof(type<code_t>))
    let headerSize = u64(typeinfo sizeof(type<M3CodePageHeader>))
    let alignSize = u64(d_m3CodePageAlignSize)

    // C first guards sizeof(code_t) * i_minNumLines against UINT_MAX.
    if (codeSize == 0ul || u64(i_minNumLines) > m3_u32_max / codeSize) {
        return null
    }

    let codeBytes = codeSize * u64(i_minNumLines)

    // Preserve the C u32 page-size domain while making addition overflow
    // explicit instead of relying on unsigned wraparound.
    if (headerSize > m3_u32_max || codeBytes > m3_u32_max - headerSize) {
        return null
    }

    let pageSizeUnaligned = headerSize + codeBytes

    // C alignment: (size + align - 1) & ~(align - 1). Guard the addition
    // before performing it so an impossible page returns null deterministically.
    let alignMask = alignSize - 1ul
    if (pageSizeUnaligned > m3_u32_max - alignMask) {
        return null
    }

    let pageSize = (pageSizeUnaligned + alignMask) & ~alignMask
    if (pageSize == 0ul || pageSize > m3_u32_max) {
        return null
    }

    let memory = m3_Malloc_Impl(pageSize)
    if (memory == null) {
        return null
    }

    unsafe {
        var page = reinterpret<IM3CodePage>(memory)

        ++i_runtime.newCodePageSequence
        page.info.sequence = i_runtime.newCodePageSequence
        page.info.numLines = u32((pageSize - headerSize) / codeSize)

        // lineIndex, usageCount and next are already zero/null because
        // m3_Malloc_Impl preserves wasm3's zero-initialized allocation contract.
        return page
    }
}


// ============================================================================
// 2. FreeCodePages
// ============================================================================


def public FreeCodePages(var io_list : IM3CodePage&) {
    var page = io_list

    while (page != null) {
        var next = page.info.next
        unsafe {
            m3_Free_Impl(reinterpret<void?>(page))
        }
        page = next
    }

    io_list = null
}


// ============================================================================
// 3. NumFreeLines
// ============================================================================


def public NumFreeLines(var i_page : IM3CodePage) : u32 {
    d_m3Assert(
        i_page.info.lineIndex <= i_page.info.numLines,
        "NumFreeLines: lineIndex exceeds numLines"
    )

    return i_page.info.numLines - i_page.info.lineIndex
}


// ============================================================================
// 4. EmitWord_impl
// ============================================================================


/* C m3_code.h: #define EmitWord(page, val) EmitWord_impl((page), (const void *)(val)) */
// The word goes through u64 on purpose: the daslang AOT backend lowers
// `reinterpret<void?>(x)` of a non-pointer value (a function, IM3Operation)
// to the address of x, while the interpreter yields x's own bits; through
// u64 both backends store the function's bits, which is what C's cast does.
def public EmitWord(var i_page : IM3CodePage; i_word : auto) {
    unsafe {
        EmitWord_impl(i_page, reinterpret<void?>(reinterpret<u64>(i_word)))
    }
}


def public EmitWord_impl(var i_page : IM3CodePage; i_word : void?) {
    d_m3Assert(
        i_page.info.lineIndex + 1u <= i_page.info.numLines,
        "EmitWord_impl: code page overflow"
    )

    unsafe {
        var code = GetPageStartPC(i_page)
        code[i_page.info.lineIndex] = i_word
    }
    ++i_page.info.lineIndex
}


// ============================================================================
// 5. EmitWord32
// ============================================================================


def public EmitWord32(var i_page : IM3CodePage; i_word : u32) {
    d_m3Assert(
        i_page.info.lineIndex + 1u <= i_page.info.numLines,
        "EmitWord32: code page overflow"
    )

    unsafe {
        var dst = reinterpret<u32?>(GetPagePC(i_page))
        *dst = i_word
    }
    ++i_page.info.lineIndex
}


// ============================================================================
// 6. EmitWord64
// ============================================================================


def public EmitWord64(var i_page : IM3CodePage; i_word : u64) {
    let codeSize = u32(typeinfo sizeof(type<code_t>))
    let slots = codeSize == 4u ? 2u : 1u

    d_m3Assert(
        i_page.info.lineIndex + slots <= i_page.info.numLines,
        "EmitWord64: code page overflow"
    )

    unsafe {
        var dst = reinterpret<u64?>(GetPagePC(i_page))
        *dst = i_word
    }
    i_page.info.lineIndex += slots
}


// ============================================================================
// 7. GetPageStartPC
// ============================================================================


def public GetPageStartPC(var i_page : IM3CodePage) : pc_t {
    unsafe {
        return addr(i_page.code[0])
    }
}


// ============================================================================
// 8. GetPagePC
// ============================================================================


def public GetPagePC(var i_page : IM3CodePage) : pc_t {
    if (i_page == null) {
        return null
    }

    unsafe {
        var pc = GetPageStartPC(i_page)
        pc += int(i_page.info.lineIndex)
        return pc
    }
}


// ============================================================================
// 9. PushCodePage
// ============================================================================


def public PushCodePage(
                        var io_list : IM3CodePage&;
                        var i_codePage : IM3CodePage
                        ) {
    var next = io_list
    i_codePage.info.next = next
    io_list = i_codePage
}


// ============================================================================
// 10. PopCodePage
// ============================================================================


def public PopCodePage(var io_list : IM3CodePage&) : IM3CodePage {
    var page = io_list
    var next = page.info.next
    io_list = next
    page.info.next = null

    return page
}


// ============================================================================
// 11. FindCodePageEnd
// ============================================================================


def public FindCodePageEnd(
                           var i_list : IM3CodePage;
                           var o_end : IM3CodePage&
                           ) : u32 {
    var numPages = 0u
    o_end = null
    while (i_list != null) {
        o_end = i_list
        ++numPages
        i_list = i_list.info.next
    }

    return numPages
}


// ============================================================================
// 12. CountCodePages
// ============================================================================


def public CountCodePages(var i_list : IM3CodePage) : u32 {
    var unused : IM3CodePage
    return FindCodePageEnd(i_list, unused)
}


// ============================================================================
// 13. GetEndCodePage
// ============================================================================


def public GetEndCodePage(var i_list : IM3CodePage) : IM3CodePage {
    var end : IM3CodePage
    FindCodePageEnd(i_list, end)

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
    M3Runtime/M3Environment page fields and m3_code primitives; bodies
    follow the C source, with m3log and DEBUG-only branches compiled out
    under the active configuration.
*/


/* C m3_env.c: IM3CodePage RemoveCodePageOfCapacity (M3CodePage ** io_list, u32 i_minimumLineCount) */
def public RemoveCodePageOfCapacity(var io_list : IM3CodePage&; i_minimumLineCount : u32) : IM3CodePage {
    var prev : IM3CodePage = null
    var page = io_list

    while (page != null) {
        if (NumFreeLines(page) >= i_minimumLineCount) {
            d_m3Assert(page.info.usageCount == 0)
            var next = page.info.next
            if (prev != null) {
                prev.info.next = next    // mid-list
            } else {
                io_list = next           // front of list
            }
            break
        }

        prev = page
        page = page.info.next
    }

    return page
}


/* C m3_env.c: IM3CodePage Environment_AcquireCodePage (IM3Environment i_environment, u32 i_minimumLineCount) */
def public Environment_AcquireCodePage(var i_environment : IM3Environment; i_minimumLineCount : u32) : IM3CodePage {
    return RemoveCodePageOfCapacity(i_environment.pagesReleased, i_minimumLineCount)
}


/* C m3_env.c: void Environment_ReleaseCodePages (IM3Environment i_environment, IM3CodePage i_codePageList) */
def public Environment_ReleaseCodePages(var i_environment : IM3Environment; var i_codePageList : IM3CodePage) {
    var end = i_codePageList

    while (end != null) {
        end.info.lineIndex = 0    // reset page
        // d_m3RecordBacktraces == false: the C mapping reset is compiled out.

        var next = end.info.next
        if (next == null) {
            break
        }

        end = next
    }

    if (end != null) {
        end.info.next = i_environment.pagesReleased
        i_environment.pagesReleased = i_codePageList
    }
}


/* C m3_env.c: void ReleaseCodePageNoTrack (IM3Runtime i_runtime, IM3CodePage i_codePage) */
def public ReleaseCodePageNoTrack(var i_runtime : IM3Runtime; var i_codePage : IM3CodePage) {
    if (i_codePage != null) {
        let pageFull = NumFreeLines(i_codePage) < d_m3CodePageFreeLinesThreshold

        if (pageFull) {
            PushCodePage(i_runtime.pagesFull, i_codePage)
        } else {
            PushCodePage(i_runtime.pagesOpen, i_codePage)
        }

        // C: m3log (emit, ...) — compiled out under the active configuration.
    }
}


/* C m3_env.c: IM3CodePage AcquireCodePageWithCapacity (IM3Runtime i_runtime, u32 i_minLineCount) */
def public AcquireCodePageWithCapacity(var i_runtime : IM3Runtime; i_minLineCount : u32) : IM3CodePage {
    var page = RemoveCodePageOfCapacity(i_runtime.pagesOpen, i_minLineCount)

    if (page == null) {
        page = Environment_AcquireCodePage(i_runtime.environment, i_minLineCount)

        if (page == null) {
            page = NewCodePage(i_runtime, i_minLineCount)
        }

        if (page != null) {
            i_runtime.numCodePages++
        }
    }

    if (page != null) {
        // C: m3log (emit, ...) — compiled out under the active configuration.
        i_runtime.numActiveCodePages++
    }

    return page
}


/* C m3_env.c: IM3CodePage AcquireCodePage (IM3Runtime i_runtime) */
def public AcquireCodePage(var i_runtime : IM3Runtime) : IM3CodePage {
    return AcquireCodePageWithCapacity(i_runtime, d_m3CodePageFreeLinesThreshold)
}


/* C m3_env.c: void ReleaseCodePage (IM3Runtime i_runtime, IM3CodePage i_codePage) */
def public ReleaseCodePage(var i_runtime : IM3Runtime; var i_codePage : IM3CodePage) {
    if (i_codePage != null) {
        ReleaseCodePageNoTrack(i_runtime, i_codePage)
        i_runtime.numActiveCodePages--

        // C: DEBUG-only page accounting and m3log are compiled out.
    }
}

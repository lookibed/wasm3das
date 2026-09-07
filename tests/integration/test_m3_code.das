options gen2
options indenting = 4

require dastest/testing_boost
require ../../source/m3_code.das
require ../../source/m3_types.das


def private fail(message : string) {
    panic("test_m3_code: {message}")
}


def private check(condition : bool; message : string) {
    if (!condition) {
        fail(message)
    }
}


def private code_size() : u32 {
    return u32(typeinfo sizeof(type<code_t>))
}


def private header_size() : u32 {
    return u32(typeinfo sizeof(type<M3CodePageHeader>))
}


def private expected_page_size(i_minNumLines : u32) : u64 {
    let raw = u64(header_size()) + u64(code_size()) * u64(i_minNumLines)
    let mask = u64(d_m3CodePageAlignSize) - 1ul
    return (raw + mask) & ~mask
}


def private expected_num_lines(i_minNumLines : u32) : u32 {
    return u32((expected_page_size(i_minNumLines) - u64(header_size())) / u64(code_size()))
}


// C m3_NewRuntime: m3_AllocStruct (M3Runtime) - a zeroed host allocation, so
// the test allocates the runtime the same way (docs/memory-ownership.md).
def private alloc_runtime() : M3Runtime? {
    return unsafe(reinterpret<M3Runtime?>(m3_Malloc_Impl(u64(typeinfo sizeof(type<M3Runtime>)))))
}


def private new_page(var runtime : M3Runtime?; min_lines : u32) : IM3CodePage {
    unsafe {
        var page = NewCodePage(runtime, min_lines)
        check(page != null, "NewCodePage({min_lines}) returned null")
        return page
    }
}


def private free_page(var page : IM3CodePage) {
    FreeCodePages(page)
    check(page == null, "FreeCodePages must clear a single-page head")
}


def private slot_pc(var page : IM3CodePage; index : u32) : pc_t {
    unsafe {
        var pc = GetPageStartPC(page)
        pc += int(index)
        return pc
    }
}


def private read_u32_slot(var page : IM3CodePage; index : u32) : u32 {
    unsafe {
        let src = reinterpret<u32?>(slot_pc(page, index))
        return *src
    }
}


def private read_u64_slot(var page : IM3CodePage; index : u32) : u64 {
    unsafe {
        let src = reinterpret<u64?>(slot_pc(page, index))
        return *src
    }
}


def private check_page_initial_state(var page : IM3CodePage; expected_sequence : u32; min_lines : u32) {
    check(page.info.lineIndex == 0u, "initial lineIndex must be zero")
    check(page.info.numLines == expected_num_lines(min_lines),
        "numLines mismatch for min_lines={min_lines}: expected {expected_num_lines(min_lines)}, got {page.info.numLines}")
    check(page.info.sequence == expected_sequence,
        "sequence mismatch: expected {expected_sequence}, got {page.info.sequence}")
    check(page.info.usageCount == 0u, "initial usageCount must be zero")
    check(page.info.next == null, "initial next must be null")
    check(intptr(GetPageStartPC(page)) - intptr(page) == u64(header_size()),
        "code[0] must begin immediately after M3CodePageHeader")

    let reconstructed_size = u64(header_size()) + u64(page.info.numLines) * u64(code_size())
    check(reconstructed_size == expected_page_size(min_lines), "reconstructed page size mismatch")
    check(reconstructed_size % u64(d_m3CodePageAlignSize) == 0ul,
        "page size must be rounded to d_m3CodePageAlignSize")
}


[test]
def test_new_code_page() {
    check(code_size() == 4u || code_size() == 8u, "code_t must have the real pointer size")
    check(d_m3CodePageAlignSize == 32768u, "default code page alignment must be 32 KiB")

    // Full m3_env.h runtime layout: heap-allocate like C m3_NewRuntime does.
    var runtime : M3Runtime? = alloc_runtime()

    var p0 = new_page(runtime, 0u)
    check_page_initial_state(p0, 1u, 0u)

    var p1 = new_page(runtime, 1u)
    check_page_initial_state(p1, 2u, 1u)

    var p2 = new_page(runtime, 100u)
    check_page_initial_state(p2, 3u, 100u)

    var p3 = new_page(runtime, 5000u)
    check_page_initial_state(p3, 4u, 5000u)
    check(p3.info.numLines >= 5000u, "aligned page must satisfy requested capacity")

    PushCodePage(p0, p1)
    PushCodePage(p0, p2)
    PushCodePage(p0, p3)
    FreeCodePages(p0)
    check(p0 == null, "creation-test list must be freed")

    // Product overflow from the original UINT_MAX / sizeof(code_t) guard.
    let impossible = 0xffffffffu / code_size() + 1u
    let sequence_before = runtime.newCodePageSequence
    unsafe {
        let rejected = NewCodePage(runtime, impossible)
        check(rejected == null, "multiplication-overflow page must be rejected")
    }
    check(runtime.newCodePageSequence == sequence_before,
        "rejected page must not consume a sequence number")

    // Raw size fits u32, but rounding it up to 32 KiB crosses UINT_MAX.
    let max_raw_lines = (0xffffffffu - header_size()) / code_size()
    unsafe {
        let alignment_overflow = NewCodePage(runtime, max_raw_lines)
        check(alignment_overflow == null, "alignment-overflow page must be rejected")
    }
    check(runtime.newCodePageSequence == sequence_before,
        "alignment-overflow page must not consume a sequence number")
    m3_Free_Impl(unsafe(reinterpret<void?>(runtime)))
}


[test]
def test_emit_words_and_pc() {
    // Full m3_env.h runtime layout: heap-allocate like C m3_NewRuntime does.
    var runtime : M3Runtime? = alloc_runtime()
    var page = new_page(runtime, 8u)

    let start_addr = intptr(GetPageStartPC(page))
    check(intptr(GetPagePC(page)) == start_addr, "initial GetPagePC must equal page start")
    check(NumFreeLines(page) == page.info.numLines, "all lines must initially be free")

    var marker = 0x12345678
    var marker_word : void?
    unsafe {
        marker_word = addr<void?>(marker)
    }

    EmitWord_impl(page, marker_word)
    check(page.info.lineIndex == 1u, "EmitWord_impl must consume one slot")
    unsafe {
        var code = GetPageStartPC(page)
        check(intptr(code[0]) == intptr(marker_word), "EmitWord_impl must preserve pointer bits")
    }

    let word32 = 0x89abcdefu
    EmitWord32(page, word32)
    check(page.info.lineIndex == 2u, "EmitWord32 must consume one slot")
    check(read_u32_slot(page, 1u) == word32, "EmitWord32 bit pattern mismatch")

    let word64 = 0x0123456789abcdeful
    let word64_start = page.info.lineIndex
    let word64_slots = code_size() == 4u ? 2u : 1u
    EmitWord64(page, word64)
    check(page.info.lineIndex == word64_start + word64_slots,
        "EmitWord64 consumed wrong number of code_t slots")
    check(read_u64_slot(page, word64_start) == word64, "EmitWord64 bit pattern mismatch")

    let pc_addr = intptr(GetPagePC(page))
    check(pc_addr - start_addr == u64(page.info.lineIndex) * u64(code_size()),
        "GetPagePC must advance by lineIndex * sizeof(code_t)")
    check(NumFreeLines(page) == page.info.numLines - page.info.lineIndex,
        "NumFreeLines mismatch after writes")

    // Multiple consecutive 32-bit values keep their exact low 32-bit patterns.
    let seq_start = page.info.lineIndex
    EmitWord32(page, 0x00000000u)
    EmitWord32(page, 0xffffffffu)
    EmitWord32(page, 0x80000001u)
    check(read_u32_slot(page, seq_start + 0u) == 0x00000000u, "sequential word32[0]")
    check(read_u32_slot(page, seq_start + 1u) == 0xffffffffu, "sequential word32[1]")
    check(read_u32_slot(page, seq_start + 2u) == 0x80000001u, "sequential word32[2]")

    free_page(page)
    check(GetPagePC(null) == null, "GetPagePC(null) must return null")
    m3_Free_Impl(unsafe(reinterpret<void?>(runtime)))
}


[test]
def test_emit_last_slot_and_overflow() {
    // Full m3_env.h runtime layout: heap-allocate like C m3_NewRuntime does.
    var runtime : M3Runtime? = alloc_runtime()

    // EmitWord32 succeeds in the last slot and fails on the next write.
    var page32 = new_page(runtime, 1u)
    page32.info.lineIndex = page32.info.numLines - 1u
    EmitWord32(page32, 0xa5a55a5au)
    check(page32.info.lineIndex == page32.info.numLines, "EmitWord32 must reach exact end")
    check(read_u32_slot(page32, page32.info.numLines - 1u) == 0xa5a55a5au,
        "last-slot word32 bits")

    var overflow32 = false
    try {
        EmitWord32(page32, 1u)
    } recover {
        overflow32 = true
    }
    check(overflow32, "EmitWord32 overflow must assert")
    check(page32.info.lineIndex == page32.info.numLines,
        "failed EmitWord32 must not advance lineIndex")
    free_page(page32)

    // EmitWord64 uses one slot on 64-bit targets and two on 32-bit targets.
    var page64 = new_page(runtime, 2u)
    let slots64 = code_size() == 4u ? 2u : 1u
    page64.info.lineIndex = page64.info.numLines - slots64
    let start64 = page64.info.lineIndex
    EmitWord64(page64, 0xfedcba9876543210ul)
    check(page64.info.lineIndex == page64.info.numLines, "EmitWord64 must reach exact end")
    check(read_u64_slot(page64, start64) == 0xfedcba9876543210ul, "last EmitWord64 bits")

    var overflow64 = false
    try {
        EmitWord64(page64, 0ul)
    } recover {
        overflow64 = true
    }
    check(overflow64, "EmitWord64 overflow must assert")
    check(page64.info.lineIndex == page64.info.numLines,
        "failed EmitWord64 must not advance lineIndex")
    free_page(page64)

    // EmitWord_impl has the same one-slot capacity rule.
    var page_ptr = new_page(runtime, 1u)
    page_ptr.info.lineIndex = page_ptr.info.numLines - 1u
    EmitWord_impl(page_ptr, null)
    check(page_ptr.info.lineIndex == page_ptr.info.numLines, "EmitWord_impl must reach exact end")
    var overflow_ptr = false
    try {
        EmitWord_impl(page_ptr, null)
    } recover {
        overflow_ptr = true
    }
    check(overflow_ptr, "EmitWord_impl overflow must assert")
    free_page(page_ptr)
    m3_Free_Impl(unsafe(reinterpret<void?>(runtime)))
}


[test]
def test_code_page_list() {
    var empty_list : IM3CodePage
    var end : IM3CodePage

    check(CountCodePages(empty_list) == 0u, "empty CountCodePages")
    check(GetEndCodePage(empty_list) == null, "empty GetEndCodePage")
    check(FindCodePageEnd(empty_list, end) == 0u, "empty FindCodePageEnd count")
    check(end == null, "empty FindCodePageEnd end")

    // Full m3_env.h runtime layout: heap-allocate like C m3_NewRuntime does.
    var runtime : M3Runtime? = alloc_runtime()
    var list : IM3CodePage
    var pages : array<IM3CodePage>
    pages |> reserve(5)

    // Array exists only in the test to remember expected node identities; the
    // implementation itself remains the required singly-linked list.
    for (i in range(5)) {
        var page = new_page(runtime, u32(i + 1))
        pages |> push(page)
        PushCodePage(list, page)
        check(CountCodePages(list) == u32(i + 1), "CountCodePages after push {i + 1}")
        check(list == page, "PushCodePage must replace list head")
    }

    check(list == pages[4], "five-node list head must be last pushed page")
    check(list.info.next == pages[3], "LIFO link 5 -> 4")
    check(pages[3].info.next == pages[2], "LIFO link 4 -> 3")
    check(pages[2].info.next == pages[1], "LIFO link 3 -> 2")
    check(pages[1].info.next == pages[0], "LIFO link 2 -> 1")
    check(pages[0].info.next == null, "oldest page must terminate list")

    let head_before = list
    let count = FindCodePageEnd(list, end)
    check(count == 5u, "FindCodePageEnd count for five nodes")
    check(end == pages[0], "FindCodePageEnd must return tail")
    check(GetEndCodePage(list) == pages[0], "GetEndCodePage must return tail")
    check(list == head_before, "traversal must not change list head")
    check(CountCodePages(list) == 5u, "traversal must not change list contents")

    var popped = PopCodePage(list)
    check(popped == pages[4], "PopCodePage must remove current head")
    check(list == pages[3], "PopCodePage must advance list head")
    check(popped.info.next == null, "popped page next must be cleared")
    check(CountCodePages(list) == 4u, "count after pop")

    FreeCodePages(popped)
    check(popped == null, "popped page must be independently freeable")
    FreeCodePages(list)
    check(list == null, "remaining list must be freed and cleared")

    pages |> clear()
    unsafe {
        delete pages
    }
    m3_Free_Impl(unsafe(reinterpret<void?>(runtime)))
}


[test]
def test_free_code_pages() {
    var empty_list : IM3CodePage
    FreeCodePages(empty_list)
    check(empty_list == null, "freeing empty list must leave null head")

    // Full m3_env.h runtime layout: heap-allocate like C m3_NewRuntime does.
    var runtime : M3Runtime? = alloc_runtime()

    // Raw malloc/free are not represented by Daslang container ownership.
    // heap_allocation_count is the available runtime counter; on runtimes where
    // raw allocations participate in it, the page cycle below must return the
    // counter to its pre-cycle baseline (the runtime itself outlives the check
    // and is deleted at the end of the test).
    let heap_before = heap_allocation_count()
    var list : IM3CodePage
    for (i in range(16)) {
        var page = new_page(runtime, u32(i + 1))
        PushCodePage(list, page)
    }
    check(CountCodePages(list) == 16u, "free test setup count")

    FreeCodePages(list)
    check(list == null, "FreeCodePages must clear multi-page head")

    let heap_after = heap_allocation_count()
    check(heap_after == heap_before,
        "raw allocation counter changed across allocate/free cycle: before={heap_before}, after={heap_after}")

    // Stress repeated ownership cycles so stale links/double-free behavior is
    // exercised even on runtimes whose heap counter does not include raw malloc.
    for (_round in range(32)) {
        var stress_list : IM3CodePage
        for (i in range(5)) {
            var page = new_page(runtime, u32(i + 1))
            PushCodePage(stress_list, page)
        }
        FreeCodePages(stress_list)
        check(stress_list == null, "stress FreeCodePages must clear head")
    }
    m3_Free_Impl(unsafe(reinterpret<void?>(runtime)))
}


[export]
def main() {
    test_new_code_page()
    test_emit_words_and_pc()
    test_emit_last_slot_and_overflow()
    test_code_page_list()
    test_free_code_pages()

    print("test_m3_code: all tests passed\n")
}
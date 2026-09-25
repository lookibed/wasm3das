options gen2
options indenting = 4

module test_m3_code shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_code
require modules/wasm3das/source/m3_types

/*
    test_m3_code.das: Eden counterpart of
    .upstream/tests/integration/test_m3_code.das.

    Every upstream [test] has a counterpart below with the same checks in the
    same order; the fail-fast check helper of the upstream file becomes the
    recording checks of eden_test, so one failing value never hides the
    others.

    Eden: the upstream tests reason about raw blocks and pointers; here a
    page is a handle into rt.codePages and its words a region of rt.code
    (source/m3_code.das, DESIGN.md sections 4.1 and 4.4), so
      - the runtime is a local `M3Runtime()` (the upstream heap-allocated it
        to get the m3_env.h layout; the struct is that layout);
      - a null page is -1, a pointer comparison a handle comparison;
      - pointer arithmetic on a pc (GetPagePC - GetPageStartPC) is index
        arithmetic in rt.code, and a slot is read as rt.code[pc] (the u32
        view is the low 32 bits of that word);
      - "code[0] begins right after the header" becomes "the page's words
        are the last numLines words of rt.code at creation";
      - the header size of the page arithmetic is C's sizeof (M3CodePageHeader)
        (M3_SIZEOF_CODE_PAGE_HEADER of m3_code), not typeinfo sizeof of the
        Eden header, whose `next` is a 4-byte handle;
      - the marker of test_emit_words_and_pc is a word value instead of the
        address of a local, and the null word of test_emit_last_slot_and_
        overflow is 0;
      - the three "overflow must assert" checks of test_emit_last_slot_and_
        overflow keep the upstream try/recover form: the over-capacity emit
        trips d_m3Assert (a panic, source/m3_core.das), recover catches it
        (DESIGN.md section 1, `try` / `recover`), and lineIndex is checked
        unchanged afterwards, for EmitWord_impl too. A guard page is created
        after the page under test before each over-capacity emit: a page's
        words are the last words of rt.code at creation, so without the guard
        the write past the end would trip the array bounds check of rt.code
        instead of d_m3Assert (recover catches both) and the test would pass
        with the assertion deleted;
      - the heap counter of test_free_code_pages has no counterpart (an
        arena slot is not an allocation); the check becomes what
        FreeCodePages promises: every page of the list is unlinked and
        reset, rt.codePages keeps its slots and rt.code its words.
    Two tests are added for the Eden shape and have no upstream counterpart:
    test_words_land_in_rt_code (every emitted word is at rt.code[pc] of an
    absolute pc, pages own disjoint regions, handles and pcs round-trip
    through u64) and test_code_page_pool (the m3_env.c pool functions hosted
    here: acquire, release to the open or full list by the free-lines
    threshold, the released pool of the runtime with lineIndex reset, the
    page counters, and the mid-list and front-of-list removal of
    RemoveCodePageOfCapacity).
*/


// ============================================================================
// Helpers
// ============================================================================


def private code_size() : u32 {
    return u32(typeinfo sizeof(type<code_t>))
}


// Eden: C's sizeof (M3CodePageHeader), the figure NewCodePage rounds with
// (upstream: typeinfo sizeof of the header struct, whose `next` was a pointer)
def private header_size() : u32 {
    return M3_SIZEOF_CODE_PAGE_HEADER
}


def private expected_page_size(i_minNumLines : u32) : u64 {
    let raw = u64(header_size()) + u64(code_size()) * u64(i_minNumLines)
    let mask = u64(d_m3CodePageAlignSize) - 1ul
    return (raw + mask) & ~mask
}


def private expected_num_lines(i_minNumLines : u32) : u32 {
    return u32((expected_page_size(i_minNumLines) - u64(header_size())) / u64(code_size()))
}


def private new_page(var t : TestRun; var runtime : M3Runtime; min_lines : u32) : IM3CodePage {
    let page = NewCodePage(runtime, min_lines)
    check(t, page != -1, "NewCodePage({min_lines}) returned null")
    return page
}


def private free_page(var t : TestRun; var runtime : M3Runtime; var page : IM3CodePage&) {
    FreeCodePages(runtime, page)
    check(t, page == -1, "FreeCodePages must clear a single-page head")
}


// Eden: the upstream `GetPageStartPC(page) + index`, index arithmetic on a pc
def private slot_pc(runtime : M3Runtime; page : IM3CodePage; index : u32) : pc_t {
    var pc = GetPageStartPC(runtime, page)
    pc = pc + int(index)
    return pc
}


// Eden: the low 32 bits of the word (C: the first four bytes of the slot)
def private read_u32_slot(runtime : M3Runtime; page : IM3CodePage; index : u32) : u32 {
    return u32(runtime.code[slot_pc(runtime, page, index)])
}


def private read_u64_slot(runtime : M3Runtime; page : IM3CodePage; index : u32) : u64 {
    return runtime.code[slot_pc(runtime, page, index)]
}


def private check_page_initial_state(var t : TestRun; runtime : M3Runtime; page : IM3CodePage; expected_sequence : u32; min_lines : u32) {
    equal(t, runtime.codePages[page].info.lineIndex, 0u, "initial lineIndex must be zero")
    equal(t, runtime.codePages[page].info.numLines, expected_num_lines(min_lines),
        "numLines mismatch for min_lines={min_lines}")
    equal(t, runtime.codePages[page].info.sequence, expected_sequence, "sequence mismatch")
    equal(t, runtime.codePages[page].info.usageCount, 0u, "initial usageCount must be zero")
    equal(t, runtime.codePages[page].info.next, -1, "initial next must be null")
    // Eden: the upstream "code[0] must begin immediately after M3CodePageHeader";
    // the page's words are the last numLines words of rt.code when it is created
    check(t, GetPageStartPC(runtime, page) >= 0, "the page's first word is a valid index into rt.code")
    equal(t, GetPageStartPC(runtime, page) + int(runtime.codePages[page].info.numLines), length(runtime.code),
        "the page's words are the last numLines words of rt.code")

    let reconstructed_size = u64(header_size()) + u64(runtime.codePages[page].info.numLines) * u64(code_size())
    equal(t, reconstructed_size, expected_page_size(min_lines), "reconstructed page size mismatch")
    equal(t, reconstructed_size % u64(d_m3CodePageAlignSize), 0ul,
        "page size must be rounded to d_m3CodePageAlignSize")
}


// ============================================================================
// Upstream tests
// ============================================================================


def test_new_code_page(var t : TestRun; fx : FixtureSource) {
    // Eden: a code word is one u64 of rt.code (upstream: the real pointer size, 4 or 8)
    equal(t, code_size(), 8u, "code_t must be one 64-bit word")
    equal(t, d_m3CodePageAlignSize, 32768u, "default code page alignment must be 32 KiB")

    // Full m3_env.h runtime layout; Eden: the struct itself
    var runtime = M3Runtime()

    var p0 = new_page(t, runtime, 0u)
    check_page_initial_state(t, runtime, p0, 1u, 0u)

    let p1 = new_page(t, runtime, 1u)
    check_page_initial_state(t, runtime, p1, 2u, 1u)

    let p2 = new_page(t, runtime, 100u)
    check_page_initial_state(t, runtime, p2, 3u, 100u)

    let p3 = new_page(t, runtime, 5000u)
    check_page_initial_state(t, runtime, p3, 4u, 5000u)
    check(t, runtime.codePages[p3].info.numLines >= 5000u, "aligned page must satisfy requested capacity")

    PushCodePage(runtime, p0, p1)
    PushCodePage(runtime, p0, p2)
    PushCodePage(runtime, p0, p3)
    FreeCodePages(runtime, p0)
    equal(t, p0, -1, "creation-test list must be freed")

    // Product overflow from the original UINT_MAX / sizeof(code_t) guard.
    let impossible = 0xffffffffu / code_size() + 1u
    let sequence_before = runtime.newCodePageSequence
    let pages_before = length(runtime.codePages)
    let words_before = length(runtime.code)
    let rejected = NewCodePage(runtime, impossible)
    equal(t, rejected, -1, "multiplication-overflow page must be rejected")
    equal(t, runtime.newCodePageSequence, sequence_before,
        "rejected page must not consume a sequence number")
    equal(t, length(runtime.codePages), pages_before, "rejected page must not consume an arena slot")
    equal(t, length(runtime.code), words_before, "rejected page must not consume words of rt.code")

    // Raw size fits u32, but rounding it up to 32 KiB crosses UINT_MAX.
    let max_raw_lines = (0xffffffffu - header_size()) / code_size()
    let alignment_overflow = NewCodePage(runtime, max_raw_lines)
    equal(t, alignment_overflow, -1, "alignment-overflow page must be rejected")
    equal(t, runtime.newCodePageSequence, sequence_before,
        "alignment-overflow page must not consume a sequence number")
    equal(t, length(runtime.codePages), pages_before, "alignment-overflow page must not consume an arena slot")
    equal(t, length(runtime.code), words_before, "alignment-overflow page must not consume words of rt.code")
}


def test_emit_words_and_pc(var t : TestRun; fx : FixtureSource) {
    var runtime = M3Runtime()
    var page = new_page(t, runtime, 8u)

    let start_addr = GetPageStartPC(runtime, page)
    equal(t, GetPagePC(runtime, page), start_addr, "initial GetPagePC must equal page start")
    equal(t, NumFreeLines(runtime, page), runtime.codePages[page].info.numLines, "all lines must initially be free")

    // Eden: a word value (upstream: the address of a local)
    let marker_word : code_t = 0x12345678ul

    EmitWord_impl(runtime, page, marker_word)
    equal(t, runtime.codePages[page].info.lineIndex, 1u, "EmitWord_impl must consume one slot")
    let code = GetPageStartPC(runtime, page)
    equal(t, runtime.code[code], marker_word, "EmitWord_impl must preserve the word bits")

    let word32 = 0x89abcdefu
    EmitWord32(runtime, page, word32)
    equal(t, runtime.codePages[page].info.lineIndex, 2u, "EmitWord32 must consume one slot")
    equal(t, read_u32_slot(runtime, page, 1u), word32, "EmitWord32 bit pattern mismatch")
    equal(t, read_u64_slot(runtime, page, 1u), u64(word32), "EmitWord32 leaves the high bits of the word zero")   // Eden

    let word64 = 0x0123456789abcdeful
    let word64_start = runtime.codePages[page].info.lineIndex
    let word64_slots = code_size() == 4u ? 2u : 1u
    EmitWord64(runtime, page, word64)
    equal(t, runtime.codePages[page].info.lineIndex, word64_start + word64_slots,
        "EmitWord64 consumed wrong number of code_t slots")
    equal(t, read_u64_slot(runtime, page, word64_start), word64, "EmitWord64 bit pattern mismatch")

    // Eden: the upstream `(pc - start) == lineIndex * sizeof(code_t)` in bytes; indices count words
    let pc_addr = GetPagePC(runtime, page)
    equal(t, pc_addr - start_addr, int(runtime.codePages[page].info.lineIndex),
        "GetPagePC must advance by lineIndex words")
    equal(t, NumFreeLines(runtime, page), runtime.codePages[page].info.numLines - runtime.codePages[page].info.lineIndex,
        "NumFreeLines mismatch after writes")

    // Multiple consecutive 32-bit values keep their exact low 32-bit patterns.
    let seq_start = runtime.codePages[page].info.lineIndex
    EmitWord32(runtime, page, 0x00000000u)
    EmitWord32(runtime, page, 0xffffffffu)
    EmitWord32(runtime, page, 0x80000001u)
    equal(t, read_u32_slot(runtime, page, seq_start + 0u), 0x00000000u, "sequential word32[0]")
    equal(t, read_u32_slot(runtime, page, seq_start + 1u), 0xffffffffu, "sequential word32[1]")
    equal(t, read_u32_slot(runtime, page, seq_start + 2u), 0x80000001u, "sequential word32[2]")

    free_page(t, runtime, page)
    equal(t, GetPagePC(runtime, -1), -1, "GetPagePC(null) must return null")
}


def test_emit_last_slot_and_overflow(var t : TestRun; fx : FixtureSource) {
    var runtime = M3Runtime()

    // EmitWord32 succeeds in the last slot and fails on the next write.
    var page32 = new_page(t, runtime, 1u)
    runtime.codePages[page32].info.lineIndex = runtime.codePages[page32].info.numLines - 1u
    EmitWord32(runtime, page32, 0xa5a55a5au)
    equal(t, runtime.codePages[page32].info.lineIndex, runtime.codePages[page32].info.numLines, "EmitWord32 must reach exact end")
    equal(t, read_u32_slot(runtime, page32, runtime.codePages[page32].info.numLines - 1u), 0xa5a55a5au,
        "last-slot word32 bits")

    // Eden: a guard page after page32 makes the slot past its end a valid
    // index of rt.code, so only d_m3Assert can stop the emit (see the header)
    var guard32 = new_page(t, runtime, 1u)
    var overflow32 = false
    try {
        EmitWord32(runtime, page32, 1u)
    } recover {
        overflow32 = true
    }
    check(t, overflow32, "EmitWord32 overflow must assert")
    equal(t, runtime.codePages[page32].info.lineIndex, runtime.codePages[page32].info.numLines,
        "failed EmitWord32 must not advance lineIndex")
    free_page(t, runtime, guard32)
    free_page(t, runtime, page32)

    // EmitWord64 uses one slot on 64-bit targets and two on 32-bit targets.
    var page64 = new_page(t, runtime, 2u)
    let slots64 = code_size() == 4u ? 2u : 1u
    runtime.codePages[page64].info.lineIndex = runtime.codePages[page64].info.numLines - slots64
    let start64 = runtime.codePages[page64].info.lineIndex
    EmitWord64(runtime, page64, 0xfedcba9876543210ul)
    equal(t, runtime.codePages[page64].info.lineIndex, runtime.codePages[page64].info.numLines, "EmitWord64 must reach exact end")
    equal(t, read_u64_slot(runtime, page64, start64), 0xfedcba9876543210ul, "last EmitWord64 bits")

    var guard64 = new_page(t, runtime, 1u)   // Eden: guard page, as above
    var overflow64 = false
    try {
        EmitWord64(runtime, page64, 0ul)
    } recover {
        overflow64 = true
    }
    check(t, overflow64, "EmitWord64 overflow must assert")
    equal(t, runtime.codePages[page64].info.lineIndex, runtime.codePages[page64].info.numLines,
        "failed EmitWord64 must not advance lineIndex")
    free_page(t, runtime, guard64)
    free_page(t, runtime, page64)

    // EmitWord_impl has the same one-slot capacity rule.
    var page_ptr = new_page(t, runtime, 1u)
    runtime.codePages[page_ptr].info.lineIndex = runtime.codePages[page_ptr].info.numLines - 1u
    EmitWord_impl(runtime, page_ptr, 0ul)   // Eden: the null word (upstream: null)
    equal(t, runtime.codePages[page_ptr].info.lineIndex, runtime.codePages[page_ptr].info.numLines, "EmitWord_impl must reach exact end")
    equal(t, read_u64_slot(runtime, page_ptr, runtime.codePages[page_ptr].info.numLines - 1u), 0ul, "last EmitWord_impl word is the null word")
    var guard_ptr = new_page(t, runtime, 1u)   // Eden: guard page, as above
    var overflow_ptr = false
    try {
        EmitWord_impl(runtime, page_ptr, 0ul)   // Eden: the null word (upstream: null)
    } recover {
        overflow_ptr = true
    }
    check(t, overflow_ptr, "EmitWord_impl overflow must assert")
    // Eden: checked here as well, as for EmitWord32 and EmitWord64
    equal(t, runtime.codePages[page_ptr].info.lineIndex, runtime.codePages[page_ptr].info.numLines,
        "failed EmitWord_impl must not advance lineIndex")
    free_page(t, runtime, guard_ptr)
    free_page(t, runtime, page_ptr)
}


def test_code_page_list(var t : TestRun; fx : FixtureSource) {
    var runtime = M3Runtime()
    let empty_list : IM3CodePage = -1
    var end : IM3CodePage = -1

    equal(t, CountCodePages(runtime, empty_list), 0u, "empty CountCodePages")
    equal(t, GetEndCodePage(runtime, empty_list), -1, "empty GetEndCodePage")
    equal(t, FindCodePageEnd(runtime, empty_list, end), 0u, "empty FindCodePageEnd count")
    equal(t, end, -1, "empty FindCodePageEnd end")

    var list : IM3CodePage = -1
    var pages : array<IM3CodePage>
    pages |> reserve(5)

    // Array exists only in the test to remember expected node identities; the
    // implementation itself remains the required singly-linked list.
    for (i in range(5)) {
        let page = new_page(t, runtime, u32(i + 1))
        pages |> push(page)
        PushCodePage(runtime, list, page)
        equal(t, CountCodePages(runtime, list), u32(i + 1), "CountCodePages after push {i + 1}")
        equal(t, list, page, "PushCodePage must replace list head")
    }

    equal(t, list, pages[4], "five-node list head must be last pushed page")
    equal(t, runtime.codePages[list].info.next, pages[3], "LIFO link 5 -> 4")
    equal(t, runtime.codePages[pages[3]].info.next, pages[2], "LIFO link 4 -> 3")
    equal(t, runtime.codePages[pages[2]].info.next, pages[1], "LIFO link 3 -> 2")
    equal(t, runtime.codePages[pages[1]].info.next, pages[0], "LIFO link 2 -> 1")
    equal(t, runtime.codePages[pages[0]].info.next, -1, "oldest page must terminate list")

    let head_before = list
    let count = FindCodePageEnd(runtime, list, end)
    equal(t, count, 5u, "FindCodePageEnd count for five nodes")
    equal(t, end, pages[0], "FindCodePageEnd must return tail")
    equal(t, GetEndCodePage(runtime, list), pages[0], "GetEndCodePage must return tail")
    equal(t, list, head_before, "traversal must not change list head")
    equal(t, CountCodePages(runtime, list), 5u, "traversal must not change list contents")

    var popped = PopCodePage(runtime, list)
    equal(t, popped, pages[4], "PopCodePage must remove current head")
    equal(t, list, pages[3], "PopCodePage must advance list head")
    equal(t, runtime.codePages[popped].info.next, -1, "popped page next must be cleared")
    equal(t, CountCodePages(runtime, list), 4u, "count after pop")

    let popped_slot = popped
    FreeCodePages(runtime, popped)
    equal(t, popped, -1, "popped page must be independently freeable")
    FreeCodePages(runtime, list)
    equal(t, list, -1, "remaining list must be freed and cleared")

    // Eden: a freed page is unlinked and reset in its arena slot
    equal(t, runtime.codePages[popped_slot].info.numLines, 0u, "freed page has no words")
    equal(t, runtime.codePages[popped_slot].code, -1, "freed page has no region")
    for (i in range(4)) {
        equal(t, runtime.codePages[pages[i]].info.next, -1, "freed page {i} is unlinked")
        equal(t, runtime.codePages[pages[i]].info.numLines, 0u, "freed page {i} has no words")
    }

    pages |> clear()
}


def test_free_code_pages(var t : TestRun; fx : FixtureSource) {
    var runtime = M3Runtime()
    var empty_list : IM3CodePage = -1
    FreeCodePages(runtime, empty_list)
    equal(t, empty_list, -1, "freeing empty list must leave null head")

    // Eden: the upstream compared heap_allocation_count() across the cycle;
    // an arena slot is not an allocation, so the check is what FreeCodePages
    // promises: the slots stay (handles stable), the words stay (pcs stable),
    // every page of the list is unlinked and reset
    var list : IM3CodePage = -1
    var pages : array<IM3CodePage>
    for (i in range(16)) {
        let page = new_page(t, runtime, u32(i + 1))
        pages |> push(page)
        PushCodePage(runtime, list, page)
    }
    equal(t, CountCodePages(runtime, list), 16u, "free test setup count")
    let slots_after_setup = length(runtime.codePages)
    let words_after_setup = length(runtime.code)

    FreeCodePages(runtime, list)
    equal(t, list, -1, "FreeCodePages must clear multi-page head")

    equal(t, length(runtime.codePages), slots_after_setup, "the arena keeps its slots across a free")
    equal(t, length(runtime.code), words_after_setup, "rt.code keeps its words across a free")
    var all_reset = true
    for (page in pages) {
        let reset_next = runtime.codePages[page].info.next == -1
        let reset_lines = runtime.codePages[page].info.numLines == 0u
        let reset_index = runtime.codePages[page].info.lineIndex == 0u
        let reset_code = runtime.codePages[page].code == -1
        if (!reset_next || !reset_lines || !reset_index || !reset_code) {
            all_reset = false
        }
    }
    check(t, all_reset, "every freed page is unlinked and reset")

    // Stress repeated ownership cycles so stale links are exercised.
    var stress_ok = true
    for (_round in range(32)) {
        var stress_list : IM3CodePage = -1
        for (i in range(5)) {
            let page = new_page(t, runtime, u32(i + 1))
            PushCodePage(runtime, stress_list, page)
        }
        if (CountCodePages(runtime, stress_list) != 5u) {
            stress_ok = false
        }
        FreeCodePages(runtime, stress_list)
        if (stress_list != -1) {
            stress_ok = false
        }
    }
    check(t, stress_ok, "stress FreeCodePages must clear head")
    equal(t, length(runtime.codePages), slots_after_setup + 32 * 5, "every stress page took one arena slot")
}


// ============================================================================
// Eden: words land at rt.code[pc]
// ============================================================================


def test_words_land_in_rt_code(var t : TestRun; fx : FixtureSource) {
    var runtime = M3Runtime()
    equal(t, length(runtime.code), 0, "a new runtime has no code words")

    let a = new_page(t, runtime, 4u)
    let b = new_page(t, runtime, 4u)
    equal(t, a, 0, "the first page is handle 0")
    equal(t, b, 1, "the second page is handle 1")
    equal(t, length(runtime.codePages), 2, "two arena slots")

    // the pages own disjoint regions of rt.code, in creation order
    let start_a = GetPageStartPC(runtime, a)
    let start_b = GetPageStartPC(runtime, b)
    equal(t, start_a, 0, "page a starts at word 0")
    equal(t, start_b, start_a + int(runtime.codePages[a].info.numLines), "page b starts right after page a's words")
    equal(t, length(runtime.code), start_b + int(runtime.codePages[b].info.numLines), "rt.code holds exactly both pages")

    // an op index, an immediate, a pc and a handle, each at the pc GetPagePC gave
    let pc_op = GetPagePC(runtime, a)
    EmitWord(runtime, a, 7ul)                 // an op by table index
    let pc_imm = GetPagePC(runtime, a)
    EmitWord(runtime, a, 0xdeadbeefcafef00dul)   // an immediate by value
    let pc_pc = GetPagePC(runtime, a)
    EmitWord(runtime, a, u64(start_b))        // a pc as u64(int)
    let pc_handle = GetPagePC(runtime, a)
    EmitWord(runtime, a, u64(-1))             // a null handle as u64(int)

    equal(t, pc_op, start_a, "the first word's pc is the page start")
    equal(t, pc_imm, start_a + 1, "pcs advance by one word")
    equal(t, pc_pc, start_a + 2, "pcs advance by one word (2)")
    equal(t, pc_handle, start_a + 3, "pcs advance by one word (3)")
    equal(t, GetPagePC(runtime, a), start_a + 4, "GetPagePC is the next free word")
    equal(t, runtime.code[pc_op], 7ul, "the op index is at rt.code[pc]")
    equal(t, runtime.code[pc_imm], 0xdeadbeefcafef00dul, "the immediate is at rt.code[pc]")
    equal(t, int(runtime.code[pc_pc]), start_b, "the pc round-trips through u64")
    equal(t, int(runtime.code[pc_handle]), -1, "the null handle round-trips through u64")

    // page b's words are untouched by page a's emits
    var b_clean = true
    for (i in range(int(runtime.codePages[b].info.numLines))) {
        if (runtime.code[start_b + i] != 0ul) {
            b_clean = false
        }
    }
    check(t, b_clean, "page b's words stay zero")
    equal(t, runtime.codePages[b].info.lineIndex, 0u, "page b's lineIndex is untouched")

    // a write through page b lands in b's region, after a's
    EmitWord32(runtime, b, 0x11223344u)
    equal(t, runtime.code[start_b], 0x11223344ul, "page b's first word is at its start pc")
    equal(t, GetPagePC(runtime, b), start_b + 1, "page b's pc advanced")
    equal(t, runtime.code[start_a + 4], 0ul, "page a's next free word stays zero")

    // the release pool of the runtime starts empty
    equal(t, runtime.pagesReleased, -1, "M3Runtime.pagesReleased starts null")
}


// ============================================================================
// Eden: the m3_env.c pool functions hosted here
// ============================================================================


def test_code_page_pool(var t : TestRun; fx : FixtureSource) {
    var runtime = M3Runtime()

    // a fresh runtime: the first acquire creates a page
    let first = AcquireCodePage(runtime)
    equal(t, first, 0, "AcquireCodePage creates the first page")
    equal(t, runtime.numCodePages, 1u, "numCodePages counts the new page")
    equal(t, runtime.numActiveCodePages, 1u, "numActiveCodePages counts the acquired page")
    equal(t, runtime.pagesOpen, -1, "the new page is not on pagesOpen while acquired")
    check(t, runtime.codePages[first].info.numLines >= d_m3CodePageFreeLinesThreshold,
        "AcquireCodePage asks for at least the free-lines threshold")

    // release with room left: the page goes to pagesOpen and keeps its words
    EmitWord(runtime, first, 1ul)
    EmitWord(runtime, first, 2ul)
    ReleaseCodePage(runtime, first)
    equal(t, runtime.pagesOpen, first, "a page with free lines is released to pagesOpen")
    equal(t, runtime.pagesFull, -1, "pagesFull stays empty")
    equal(t, runtime.numActiveCodePages, 0u, "ReleaseCodePage decrements numActiveCodePages")
    equal(t, runtime.numCodePages, 1u, "ReleaseCodePage keeps numCodePages")

    // re-acquire: the open page comes back with its content, no new page
    let again = AcquireCodePageWithCapacity(runtime, 1u)
    equal(t, again, first, "an open page with the capacity is reused")
    equal(t, runtime.pagesOpen, -1, "the reused page left pagesOpen")
    equal(t, runtime.numCodePages, 1u, "no page was created for the reuse")
    equal(t, runtime.numActiveCodePages, 1u, "the reused page is active")
    equal(t, runtime.codePages[first].info.lineIndex, 2u, "an open page keeps its lineIndex")
    equal(t, runtime.code[GetPageStartPC(runtime, first) + 1], 2ul, "an open page keeps its words")

    // release with fewer free lines than the threshold: the page goes to pagesFull
    runtime.codePages[first].info.lineIndex = runtime.codePages[first].info.numLines - (d_m3CodePageFreeLinesThreshold - 1u)
    ReleaseCodePage(runtime, first)
    equal(t, runtime.pagesFull, first, "a page below the threshold is released to pagesFull")
    equal(t, runtime.pagesOpen, -1, "a full page is not on pagesOpen")
    equal(t, runtime.numActiveCodePages, 0u, "numActiveCodePages back to zero")

    // the next acquire cannot use the full page: a second page is created
    let second = AcquireCodePage(runtime)
    equal(t, second, 1, "a second page is created when no open page fits")
    equal(t, runtime.numCodePages, 2u, "numCodePages counts the second page")
    equal(t, runtime.numActiveCodePages, 1u, "the second page is active")

    // ReleaseCodePageNoTrack: the list placement without the active counter
    ReleaseCodePageNoTrack(runtime, second)
    equal(t, runtime.pagesOpen, second, "ReleaseCodePageNoTrack pushes to pagesOpen")
    equal(t, runtime.numActiveCodePages, 1u, "ReleaseCodePageNoTrack keeps numActiveCodePages")
    ReleaseCodePage(runtime, -1)
    equal(t, runtime.numActiveCodePages, 1u, "ReleaseCodePage(null) does nothing")
    ReleaseCodePageNoTrack(runtime, -1)
    equal(t, runtime.pagesOpen, second, "ReleaseCodePageNoTrack(null) does nothing")
    runtime.numActiveCodePages = 0u

    // Environment_ReleaseCodePages: the runtime's released pool, lineIndex reset
    var list : IM3CodePage = -1
    let third = NewCodePage(runtime, 1u)
    let fourth = NewCodePage(runtime, 1u)
    EmitWord(runtime, third, 3ul)
    EmitWord(runtime, fourth, 4ul)
    EmitWord(runtime, fourth, 44ul)
    PushCodePage(runtime, list, third)
    PushCodePage(runtime, list, fourth)      // list: fourth -> third
    Environment_ReleaseCodePages(runtime, list)
    equal(t, runtime.pagesReleased, fourth, "the released list becomes the pool head")
    equal(t, runtime.codePages[fourth].info.next, third, "the released list keeps its order")
    equal(t, runtime.codePages[third].info.next, -1, "the pool ends at the list's tail")
    equal(t, runtime.codePages[third].info.lineIndex, 0u, "a released page's lineIndex is reset")
    equal(t, runtime.codePages[fourth].info.lineIndex, 0u, "a released page's lineIndex is reset (2)")
    equal(t, runtime.code[GetPageStartPC(runtime, fourth)], 4ul, "the old words stay in rt.code until overwritten")
    Environment_ReleaseCodePages(runtime, -1)
    equal(t, runtime.pagesReleased, fourth, "releasing an empty list leaves the pool")

    // a second release links its tail to the previous pool head
    var more : IM3CodePage = -1
    let fifth = NewCodePage(runtime, 1u)
    PushCodePage(runtime, more, fifth)
    Environment_ReleaseCodePages(runtime, more)
    equal(t, runtime.pagesReleased, fifth, "the newest release is the pool head")
    equal(t, runtime.codePages[fifth].info.next, fourth, "the new tail links to the old head")
    equal(t, CountCodePages(runtime, runtime.pagesReleased), 3u, "the pool holds three pages")

    // Environment_AcquireCodePage takes from the pool; the page is reused
    let reused = Environment_AcquireCodePage(runtime, 1u)
    equal(t, reused, fifth, "the pool head with the capacity is acquired")
    equal(t, runtime.pagesReleased, fourth, "the pool head advanced")
    EmitWord(runtime, reused, 5ul)
    equal(t, runtime.code[GetPageStartPC(runtime, reused)], 5ul, "a reused page's emits overwrite its old words")
    equal(t, runtime.codePages[reused].info.lineIndex, 1u, "a reused page emits from line 0")

    // AcquireCodePageWithCapacity falls through to the pool and counts the page
    runtime.pagesOpen = -1
    let pages_before = runtime.numCodePages
    let from_pool = AcquireCodePageWithCapacity(runtime, 1u)
    equal(t, from_pool, fourth, "no open page: the pool is asked next")
    equal(t, runtime.numCodePages, pages_before + 1u, "a page from the pool counts as new to the runtime")
    equal(t, runtime.numActiveCodePages, 1u, "the pooled page is active")
    equal(t, runtime.pagesReleased, third, "the pool head advanced (2)")

    // RemoveCodePageOfCapacity: mid-list and front-of-list removal
    var cap_list : IM3CodePage = -1
    let c0 = NewCodePage(runtime, 1u)
    let c1 = NewCodePage(runtime, 1u)
    let c2 = NewCodePage(runtime, 1u)
    runtime.codePages[c0].info.lineIndex = runtime.codePages[c0].info.numLines   // no free line
    runtime.codePages[c2].info.lineIndex = runtime.codePages[c2].info.numLines   // no free line
    PushCodePage(runtime, cap_list, c0)
    PushCodePage(runtime, cap_list, c1)
    PushCodePage(runtime, cap_list, c2)      // cap_list: c2 -> c1 -> c0
    let mid = RemoveCodePageOfCapacity(runtime, cap_list, 10u)
    equal(t, mid, c1, "the first page with the capacity is removed (mid-list)")
    equal(t, cap_list, c2, "a mid-list removal keeps the head")
    equal(t, runtime.codePages[c2].info.next, c0, "a mid-list removal links prev to next")
    equal(t, CountCodePages(runtime, cap_list), 2u, "two pages remain")
    let none = RemoveCodePageOfCapacity(runtime, cap_list, 10u)
    equal(t, none, -1, "no page with the capacity: null")
    equal(t, CountCodePages(runtime, cap_list), 2u, "a failed removal changes nothing")
    runtime.codePages[c2].info.lineIndex = 0u
    let front = RemoveCodePageOfCapacity(runtime, cap_list, 10u)
    equal(t, front, c2, "the head with the capacity is removed (front of list)")
    equal(t, cap_list, c0, "a front-of-list removal advances the head")
    equal(t, runtime.codePages[c2].info.next, c0, "RemoveCodePageOfCapacity does not clear next (C leaves it)")
}


// ============================================================================
// Runner
// ============================================================================


def public run_tests_m3_code(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_new_code_page")
    test_new_code_page(t, fx)
    begin_test(t, "test_emit_words_and_pc")
    test_emit_words_and_pc(t, fx)
    begin_test(t, "test_emit_last_slot_and_overflow")
    test_emit_last_slot_and_overflow(t, fx)
    begin_test(t, "test_code_page_list")
    test_code_page_list(t, fx)
    begin_test(t, "test_free_code_pages")
    test_free_code_pages(t, fx)
    begin_test(t, "test_words_land_in_rt_code")
    test_words_land_in_rt_code(t, fx)
    begin_test(t, "test_code_page_pool")
    test_code_page_pool(t, fx)
}

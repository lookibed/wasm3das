options gen2
options indenting = 4

// `shared` because m3_exec is shared and a shared module may only require shared
// modules; `private` because nothing outside the compiler ever calls into it.
module m3_exec_expand shared private

// Only daslib/ast, deliberately. It is a thin wrapper over the builtin ast_core
// bindings and costs ~15 ms of compile time; adding daslib/ast_boost and
// daslib/templates_boost for the `[infer_macro]` annotation and for qmacro costs
// ~0.65 s on every run of the port, which is a third of its whole startup. The
// macro therefore registers itself through add_new_infer_macro and builds its
// three generated nodes (ExprUnsafe, ExprLet, ExprVar) by hand.
require daslib/ast
// The native builtin string module, for `starts_with` alone: it is C++, not a
// daslang source module, so unlike ast_boost/templates_boost it adds nothing to
// the startup of the port.
require strings

/*
    The C preprocessor's counterpart for the operand readers of m3_exec.

    C wasm3 spells the operand readers as preprocessor macros (m3_exec_defs.h):

        #define immediate(TYPE)     * ((TYPE *) _pc++)
        #define slot_ptr(TYPE)      (TYPE *)   (_sp + immediate (i32))
        #define slot(TYPE)          * (TYPE *) (_sp + immediate (i32))

    so an operation body carries their expansion, not a call. m3_exec.das keeps
    them as `[inline]` functions (immediate_i32 .. slot_f64) so the 509 operation
    bodies keep the C spelling, but daslang's `[inline]` is not a preprocessor:
    every splice keeps a result temporary, an argument temporary and a block of
    its own, and daslang forbids a by-reference result, so the splice of

        let operand2 = slot_u32 (_pc, _sp)

    is eight interpreter nodes where the C expansion is two. The daslang
    interpreter charges roughly 8 ns per evaluated node
    (docs/execution-design.md), and an operation that reads two
    operand slots pays that eight times over.

    This pass is the missing preprocessor step. It runs during type inference on
    the m3_exec module only, and rewrites every call of those readers at its use
    site into exactly what the C macro leaves there:

        let operand2 = unsafe(<the reader's own read expression>)
        unsafe(_pc++)

    The expansion is not written out here: it is CLONED from the body of the
    `[inline]` helper it replaces, so the helpers in m3_exec.das stay the single
    transcription of the C macros and the two can never drift. A helper body must
    have the shape the C macro has - one read, one `_pc` advance, one result:

        unsafe {
            let|var value = <read>
            _pc++
            return value
        }

    Anything else is refused with a compile error rather than silently skipped.

    Evaluation order is preserved exactly. A statement that reads one operand and
    always completes gets the read substituted in place with the advance as the
    next statement, which is where the C preprocessor leaves it. A statement that
    reads two or more operands, or that may not complete (a return, an if, a
    loop), gets each read hoisted into a temporary in call order, each temporary
    immediately followed by its own advance, exactly as C's left-to-right
    sequence of `_pc++` side effects. A reader inside a short-circuit `&&`/`||`
    or a `?:` arm cannot be hoisted without changing which reads happen, and is
    refused with a compile error.

    `bool_reg` is deliberately NOT rewritten: its splice already folds to a
    single node (`_r0 = (a < b) ? 1 : 0`) because it has no side effect and one
    by-value argument.

    ------------------------------------------------------------------------

    The second pass, M3ExecDispatchPass, runs only under the LLVM JIT
    (`prog.policies.jit_enabled`, which is set by `-jit` and by `-exe` and is
    false for the daslang interpreter and for the `-aot`/`-ctx` emission).
    It is the other thing no compiler can do for the port: the direct-call
    dispatch.

    C stores the IM3Operation function pointer in the code page and calls it
    indirectly. gcc and the daslang interpreter are happy with that, but
    daslang lowers a call through a function value to a generic-wrapper invoke
    with an argument buffer on the stack, which LLVM never turns into a tail
    call, so under the JIT every executed operation nests a native frame until
    the wasm function returns. A DIRECT call in return position is a tail call
    for LLVM exactly as it is for gcc, so under the JIT - and only there - this
    pass turns the code-page word into an operation INDEX and dispatches it
    through generated direct calls. The C form stays the source form and every
    other tier compiles it unchanged; the full reasoning is the "Operation
    dispatch" section of m3_exec.das.

    Five bodies are replaced, all of them placeholders written out in
    m3_exec.das:

        m3_OpWord(op)   -> return m3_OpIndex(op)
        nextOpImpl,
        jumpOpImpl      -> return m3_DispatchOp(_pc, _sp, _mem, _r0, _fp0)
        m3_DispatchOp   -> let idx = m3_WordIndex(_pc), then the dispatch,
                           whose leaves are `return op_<name>(_pc, _sp, _mem,
                           _r0, _fp0)`
        m3_OpAt(idx)    -> the same tree, leaves `return @@op_<name>`
        m3_OpCount()    -> the number of operations

    The numbering is the op_* names of m3_exec sorted by byte order, which is a
    function of the source alone: nothing outside m3_exec and m3_OpIndex (the
    reverse map, built from m3_OpAt) ever sees it, and the compile tables of
    m3_compile.das keep C's IM3Operation values unchanged.

    The dispatch shape is selectable, because which one LLVM likes is an
    empirical question - `options _m3_dispatch = "<shape>"` at the top of
    m3_exec.das (see dispatch_shape below for why it is that file and not the
    entry file, and for the leading underscore):

        "chain"     (the measured default) a linear `if (idx == k) return
                    op_k (...)` per operation, which LLVM folds into a switch
                    with a jump table - one indirect jump instead of nine
                    comparisons;
        "tree"      a balanced `if (idx < mid)` tree, so an index costs
                    ceil(log2(N)) comparisons and every arm is a `jmp`;
        "noinline"  the tree, with `[hint(noinline)]` added to every operation
                    so LLVM cannot inline a small one into the dispatch and
                    grow its prologue with the hoisted constants;
        "chain_noinline"
                    the chain's jump table and the noinline hint together:
                    with no operation inlined into it the dispatch needs no
                    callee-saved register and no frame, so an operation's
                    `jmp` into it no longer re-executes a six-push prologue
                    and the arm no longer unwinds one. Measured a loss all
                    the same: the prologue is paid only by the operations
                    LLVM did NOT inline, and taking the inlining away costs
                    the hot ones two jumps each.

    The four are measured in docs/native-build.md section 6, E9 and E10.

    Hand-built AST again, for the reason at the top: daslib/ast only, no qmacro.
*/

// The reader set, in the order m3_exec.das declares it: C's immediate(TYPE),
// slot_ptr(TYPE) and slot(TYPE) for every TYPE the operations use.
def private is_reader_name(name : string) : bool {
    return (name == "immediate_i32" || name == "immediate_u32" || name == "immediate_pc" ||
        name == "immediate_code" || name == "immediate_function" || name == "immediate_module" ||
        name == "immediate_functype" || name == "immediate_rawcall" ||
        name == "slot_ptr_i8" || name == "slot_i8" || name == "slot_ptr_u8" || name == "slot_u8" ||
        name == "slot_ptr_i16" || name == "slot_i16" || name == "slot_ptr_u16" || name == "slot_u16" ||
        name == "slot_ptr_i32" || name == "slot_i32" || name == "slot_ptr_u32" || name == "slot_u32" ||
        name == "slot_ptr_i64" || name == "slot_i64" || name == "slot_ptr_u64" || name == "slot_u64" ||
        name == "slot_ptr_f32" || name == "slot_f32" || name == "slot_ptr_f64" || name == "slot_f64")
}

// One reader helper, taken apart into the two halves of the C macro. The
// readers take one (_pc) or two (_pc, _sp) parameters, so the names they expect
// at the use site are held as plain fields and the struct stays copyable.
struct private Reader {
    read : ExpressionPtr        // C: * (TYPE *) (_sp + immediate (i32)) / * ((TYPE *) _pc)
    advance : ExpressionPtr     // C: the ++ of `_pc++`
    nargs : int
    arg0 : string
    arg1 : string
}

def private expr_key(expr : ExpressionPtr) : uint64 {
    return unsafe(reinterpret<uint64>(expr))
}

// `expr is ExprBlock` / `expr as ExprBlock` for AST nodes is a variant macro of
// daslib/ast_boost, which this module deliberately does not require (see above).
// Every AST node carries its class name in __rtti, so the exact-class tests the
// shape checks need are these six casts.
def private as_block(var e : ExpressionPtr) : ExprBlock? {
    return e != null && e.__rtti == "ExprBlock" ? unsafe(reinterpret<ExprBlock?>(e)) : null
}

def private as_unsafe(var e : ExpressionPtr) : ExprUnsafe? {
    return e != null && e.__rtti == "ExprUnsafe" ? unsafe(reinterpret<ExprUnsafe?>(e)) : null
}

def private as_let(var e : ExpressionPtr) : ExprLet? {
    return e != null && e.__rtti == "ExprLet" ? unsafe(reinterpret<ExprLet?>(e)) : null
}

def private as_return(var e : ExpressionPtr) : ExprReturn? {
    return e != null && e.__rtti == "ExprReturn" ? unsafe(reinterpret<ExprReturn?>(e)) : null
}

def private as_var(var e : ExpressionPtr) : ExprVar? {
    return e != null && e.__rtti == "ExprVar" ? unsafe(reinterpret<ExprVar?>(e)) : null
}

// the typer wraps a by-value read of a variable in ExprRef2Value; the shape
// checks below are about the written source, so peel it first
def private peel(var expr : ExpressionPtr) : ExpressionPtr {
    var e = expr
    while (e != null && e.__rtti == "ExprRef2Value") {
        e = unsafe(reinterpret<ExprRef2Value?>(e)).subexpr
    }
    return e
}

// Take a reader helper apart. Returns false when the body is not the shape the
// C macro has; the caller turns that into a compile error.
def private split_reader(var fn : FunctionPtr; var out : Reader) : bool {
    var outer = as_block(fn.body)
    if (outer == null || length(outer.list) != 1) return false
    var guarded = as_unsafe(outer.list[0])
    if (guarded == null) return false
    var body = as_block(guarded.body)
    if (body == null || length(body.list) != 3) return false
    var decl = as_let(body.list[0])
    var ret = as_return(body.list[2])
    if (decl == null || ret == null || length(decl.variables) != 1) return false
    var value = decl.variables[0]
    var returned = as_var(peel(ret.subexpr))
    if (value.init == null || returned == null || returned.name != value.name ||
            empty(fn.arguments) || length(fn.arguments) > 2) return false
    out.read = value.init
    out.advance = body.list[1]
    out.nargs = length(fn.arguments)
    out.arg0 = string(fn.arguments[0].name)
    out.arg1 = out.nargs > 1 ? string(fn.arguments[1].name) : ""
    return true
}

// The two halves of a reader come out of an `unsafe { }` block and are spliced
// into a caller that has no such block of its own. `alwaysSafe` is the flag the
// compiler puts on exactly this - an [inline] splice marks its clones the same
// way ("callee-origin unsafe stays authorized via alwaysSafe") - and it is also
// what keeps LINT005 off the u32 readers, whose `reinterpret<u32?>` of the
// already-u32 `_sp` is a no-op cast the C macro spells all the same.
// Applied once to the prototype in the helper body, which is inside `unsafe`
// anyway, so every clone of it carries the flag.
class private MarkExpansionSafe : AstVisitor {
    def override preVisitExpression(var expr : ExpressionPtr) {
        expr.genFlags.alwaysSafe = true
    }
}

class private ExpandReaders : AstVisitor {
    prog : ProgramPtr
    readers : table<string; Reader>
    astChanged : bool = false
    failed : bool = false
    scanning : bool = true
    tempIndex : int = 0
    @do_not_delete func : Function?

    // scan pass: per statement, how many readers it holds and whether it is a
    // statement that always completes (so the advance may follow it)
    readCount : table<uint64; int>
    notStraight : table<uint64; bool>
    conditional : table<uint64; bool>

    // rewrite pass: the statement frames, innermost last
    frBlock : array<ExprBlock?>
    frStmt : array<ExpressionPtr>
    frInPlace : array<bool>
    frPre : array<int>
    frPost : array<int>

    // rewrite pass: the statements to splice into the blocks, applied after the walk
    recBlock : array<ExprBlock?>
    recAnchor : array<ExpressionPtr>
    recExpr : array<ExpressionPtr>
    recIsPost : array<bool>
    recOrdinal : array<int>

    def top() : int {
        return length(frStmt) - 1
    }

    def markStatement(var marks : table<uint64; bool>) {
        let t = top()
        if (t < 0) return
        marks[expr_key(frStmt[t])] = true
    }

    def override preVisitFunction(var fun : FunctionPtr) {
        func = fun
    }

    def override visitFunction(var fun : FunctionPtr) : FunctionPtr {
        func = null
        return <- fun
    }

    def override preVisitExprBlockExpression(var blk : ExprBlock?; var expr : ExpressionPtr) {
        if (scanning) {
            frStmt |> push(expr)
            return
        }
        let key = expr_key(expr)
        let n = readCount ?[key] ?? 0
        let straight = !(notStraight ?[key] ?? false)
        frBlock |> push(blk)
        frStmt |> push(expr)
        frInPlace |> push(n == 1 && straight)
        frPre |> push(0)
        frPost |> push(0)
    }

    def override visitExprBlockExpression(var blk : ExprBlock?; var expr : ExpressionPtr) : ExpressionPtr {
        let t = top()
        if (t < 0) return expr
        if (scanning) {
            frStmt |> resize(t)
            return expr
        }
        // the statement itself may have been replaced; re-anchor its records
        if (expr != frStmt[t]) {
            let moved = frPre[t] + frPost[t]
            for (i in range(length(recAnchor) - moved, length(recAnchor))) {
                recAnchor[i] = expr
            }
        }
        frBlock |> resize(t)
        frStmt |> resize(t)
        frInPlace |> resize(t)
        frPre |> resize(t)
        frPost |> resize(t)
        return expr
    }

    def override preVisitExprReturn(expr : ExprReturn?) {
        markStatement(notStraight)
    }

    def override preVisitExprBreak(expr : ExprBreak?) {
        markStatement(notStraight)
    }

    def override preVisitExprContinue(expr : ExprContinue?) {
        markStatement(notStraight)
    }

    def override preVisitExprIfThenElse(expr : ExprIfThenElse?) {
        markStatement(notStraight)
    }

    def override preVisitExprWhile(expr : ExprWhile?) {
        markStatement(notStraight)
    }

    def override preVisitExprFor(expr : ExprFor?) {
        markStatement(notStraight)
    }

    def override preVisitExprOp2(expr : ExprOp2?) {
        if (expr.op == "&&" || expr.op == "||") {
            markStatement(notStraight)
            markStatement(conditional)
        }
    }

    def override preVisitExprOp3(expr : ExprOp3?) {
        markStatement(notStraight)
        markStatement(conditional)
    }

    def argument_is(var expr : ExprCall?; index : int; name : string) : bool {
        if (index >= length(expr.arguments)) return false
        var arg = as_var(peel(expr.arguments[index]))
        return arg != null && arg.name == name
    }

    // The pass runs before type inference, so a call is still the name that was
    // written - which is exactly what the C preprocessor matches on.
    def readerOf(var expr : ExprCall?) : string {
        let name = string(expr.name)
        if (!key_exists(readers, name)) return ""
        return name
    }

    def override visitExprCall(var expr : ExprCall?) : ExpressionPtr {
        let name = readerOf(expr)
        if (empty(name)) return <- expr
        if (scanning) {
            let t = top()
            if (t < 0) {
                macro_sticky_error(prog, expr.at,
                    "m3_exec_expand: {name} is not inside a statement of a block, so its _pc advance has nowhere to go")
                failed = true
                return <- expr
            }
            let key = expr_key(frStmt[t])
            readCount[key] = (readCount ?[key] ?? 0) + 1
            return <- expr
        }
        let t = top()
        if (t < 0 || failed) return <- expr
        if (conditional ?[expr_key(frStmt[t])] ?? false) {
            macro_sticky_error(prog, expr.at,
                "m3_exec_expand: {name} sits in a short-circuit && / || or a ?: arm, where hoisting it would change which operand reads happen")
            failed = true
            return <- expr
        }
        // C passes _pc and _sp by name; the expansion is cloned from the helper
        // body, so the call site must spell the same names for the clone to bind
        var reader = readers[name]
        if (length(expr.arguments) != reader.nargs || !argument_is(expr, 0, reader.arg0) ||
                (reader.nargs > 1 && !argument_is(expr, 1, reader.arg1))) {
            macro_sticky_error(prog, expr.at,
                "m3_exec_expand: {name} must be called with the interpreter registers spelled '{reader.arg0}' '{reader.arg1}', which is what the cloned expansion binds to")
            failed = true
            return <- expr
        }
        // the helper body reads and advances inside `unsafe { }`; the clone lands
        // outside it, so each half carries its own guard. ExprUnsafe is folded away
        // before simulation, so this costs nothing at run time.
        var read = new ExprUnsafe(at = expr.at, body = clone_expression(reader.read))
        var advance = new ExprUnsafe(at = expr.at, body = clone_expression(reader.advance))
        read |> force_at(expr.at)
        advance |> force_at(expr.at)
        astChanged = true
        if (func != null) {
            func.not_inferred()
        }
        if (frInPlace[t]) {
            // C: the macro expands in place and `_pc++` sequences after it
            record(t, advance, true)
            return read
        }
        // two or more reads in one statement, or a statement that may not
        // complete: bind each read in call order, its advance right after it
        let tempName = "_m3rd{tempIndex}"
        tempIndex++
        var bind = new ExprLet(at = expr.at, atInit = expr.at)
        var temp = new Variable(at = expr.at, name := tempName,
            _type <- new TypeDecl(baseType = Type.autoinfer, at = expr.at),
            init <- read,
            flags = VariableFlags.can_shadow | VariableFlags.generated)
        emplace(bind.variables, temp)
        record(t, bind, false)
        record(t, advance, false)
        return new ExprVar(at = expr.at, name := tempName)
    }

    def record(t : int; var expr : ExpressionPtr; isPost : bool) {
        recBlock |> push(frBlock[t])
        recAnchor |> push(frStmt[t])
        recExpr |> push(expr)
        recIsPost |> push(isPost)
        if (isPost) {
            recOrdinal |> push(frPost[t])
            frPost[t] = frPost[t] + 1
        } else {
            recOrdinal |> push(frPre[t])
            frPre[t] = frPre[t] + 1
        }
    }

    // splice the recorded statements into their blocks; done after the walk
    // because ExprBlock::visit iterates `list` and an insert would invalidate it
    def apply_records() {
        for (i in range(length(recExpr))) {
            var blk = recBlock[i]
            var at = -1
            for (j in range(length(blk.list))) {
                if (blk.list[j] == recAnchor[i]) {
                    at = j
                    break
                }
            }
            if (at < 0) {
                macro_sticky_error(prog, recExpr[i].at, "m3_exec_expand: lost the statement an expansion belongs to")
                failed = true
                return
            }
            if (recIsPost[i]) {
                blk.list |> emplace(recExpr[i], at + 1 + recOrdinal[i])
            } else {
                blk.list |> emplace(recExpr[i], at)
            }
        }
    }
}

// The functions on the operation path: every operation (`def public op_<name>
// (d_m3OpSig)`, told apart by its five parameters, as M3ExecDispatchPass does)
// and the dispatch between them - nextOpImpl/jumpOpImpl, C's macros, and
// m3_DispatchOp, whose generated body splices m3_WordIndex and inlines the
// small operations under the JIT.
def private is_operation_path(var fn : FunctionPtr) : bool {
    if ((fn.name |> starts_with("op_")) && length(fn.arguments) == 5) return true
    return fn.name == "nextOpImpl" || fn.name == "jumpOpImpl" || fn.name == "m3_DispatchOp"
}

//! Expands the m3_exec operand readers at their use sites, the way the C
//! preprocessor expands immediate()/slot()/slot_ptr().
class M3ExecExpandPass : AstPassMacro {
    // The preprocessor runs before the compiler, and one visit is all the
    // rewrite needs. was `canVisitPass (prog, mod, index)` + `add_new_
    // pre_infer_macro`, the pre-infer stage gate of daslang 0.6.4-RC2; upstream
    // removed the stage between the releases and the pin bumped past it, so the
    // run-once semantics live in this flag and the registration is an infer
    // macro now. The pin that removed the stage is in scripts/daslang_pin.
    expanded : bool = false

    def override apply(prog : ProgramPtr; mod : Module?) : bool {
        // the readers live in m3_exec; every other module compiles untouched,
        // and the already-run rewrite stays out (run-once semantics, previously
        // gated by canVisitPass at index 0)
        if (mod.name != "m3_exec" || expanded) return false
        expanded = true
        // Under the LLVM JIT the expansion is a choice, not a necessity: LLVM
        // folds the temporaries of daslang's own [inline] splice, which the
        // interpreter pays node by node. `options _m3_jit_readers` in
        // m3_exec.das picks it (see jit_readers_mode); every other tier expands.
        let readersMode = prog.policies.jit_enabled ? jit_readers_mode(prog) : "expand"
        if (readersMode != "expand") {
            for_each_function(mod, "") $(var fn : FunctionPtr) {
                fn.flags.unsafeDeref = true
            }
            return readersMode == "llvm" ? inline_by_llvm(prog, mod) : false
        }
        var expander = new ExpandReaders()
        expander.prog := prog
        var ok = true
        for_each_function(mod, "") $(var fn : FunctionPtr) {
            // C dereferences _pc, _sp and the memory pointers unchecked; the
            // daslang backends test a pointer for null before a deref unless
            // the function being generated carries the unsafe_deref flag
            // (what `[unsafe_deref]` in source sets). Set here on the
            // operations and on the dispatch that chains them - the functions
            // whose own code runs once per executed wasm instruction - and on
            // nothing else of the module. Not on the readers: their bodies are
            // cloned into the operations above, and the JIT tests the flag of
            // the function it generates, so a reader's own flag would change
            // no instruction (docs/native-build.md section 7, E11).
            if (is_operation_path(fn)) {
                fn.flags.unsafeDeref = true
            }
            if (!is_reader_name(string(fn.name))) return
            var r : Reader
            if (!split_reader(fn, r)) {
                macro_sticky_error(prog, fn.at,
                    "m3_exec_expand: {fn.name} is not shaped like the C macro it ports: an unsafe block holding a value binding, a _pc advance and a return of that value")
                ok = false
                return
            }
            expander.readers[string(fn.name)] <- r
        }
        if (ok && !empty(expander.readers)) {
            var marker = new MarkExpansionSafe()
            make_visitor(*marker) $(adapter) {
                for (r in values(expander.readers)) {
                    visit(r.read, adapter)
                    visit(r.advance, adapter)
                }
            }
            unsafe {
                delete marker
            }
        }
        var result = false
        if (ok && !empty(expander.readers)) {
            // pass 1 counts the readers of each statement and marks the statements
            // an advance may not simply follow; pass 2 rewrites with that decision
            expander.scanning = true
            make_visitor(*expander) $(adapter) {
                visit_module(prog, adapter, mod)
            }
            // once every reader is expanded the scan finds nothing and the
            // remaining infer passes cost one walk, not two
            if (!expander.failed && !empty(expander.readCount)) {
                expander.scanning = false
                make_visitor(*expander) $(adapter) {
                    visit_module(prog, adapter, mod)
                }
                if (!expander.failed) {
                    expander.apply_records()
                }
            }
            result = expander.astChanged && !expander.failed
        }
        unsafe {
            delete expander
        }
        return result
    }
}

// ============================================================================
// The direct-call dispatch of the JIT tier
// ============================================================================


// `options _m3_dispatch = "<shape>"` at the top of m3_exec.das, read the way
// daslib reads its own options (dupe_detect.das, flatten.das, lint.das).
// find_arg is daslib/ast_boost, which this module deliberately does not
// require (see the require comment at the top), and it is four lines.
//
// The option has to sit in m3_exec.das and not in the entry file: m3_exec is a
// `shared` module, so it compiles as a program of its own and the ProgramPtr
// this pass is handed carries that module's options, not the entry file's
// (verified - with the option in app/wasm3.das the list here is just `gen2`
// and `indenting`). The leading underscore is what makes it a custom user
// option; daslang refuses an unregistered option without it.
def private dispatch_shape(prog : ProgramPtr) : string {
    for (a in prog._options) {
        if (a.name == "_m3_dispatch" && a.basicType == Type.tString) return string(a.sValue)
    }
    // the measured default, docs/native-build.md section 6, E9
    return "chain_noinline"
}

// `options _m3_jit_readers = "<mode>"` at the top of m3_exec.das, read the same
// way and for the same reason as `_m3_dispatch`: how the operand readers and the
// other [inline] helpers of the operations reach the LLVM JIT tier.
//
//     "expand"  the reader expansion of M3ExecExpandPass, what every other tier
//               compiles;
//     "splice"  no expansion: daslang's own [inline] splice of the readers,
//               whose result and argument temporaries LLVM folds;
//     "llvm"    no expansion and no splice: the [inline] helpers of m3_exec
//               lose the daslang inliner's contract and carry
//               `[hint(alwaysinline)]`, so LLVM inlines the calls itself.
def private jit_readers_mode(prog : ProgramPtr) : string {
    for (a in prog._options) {
        if (a.name == "_m3_jit_readers" && a.basicType == Type.tString) return string(a.sValue)
    }
    return "expand"
}

// The "llvm" mode of jit_readers_mode: every [inline] function of m3_exec is
// handed to LLVM's inliner instead of daslang's. Only flags and an annotation
// change, so nothing is re-inferred. The memory accessors of m3_exec_defs stay
// [inline]: that module is already compiled when this pass runs, and clearing
// its functions' contract from here crashes `daslang -exe` (a segmentation
// fault in the compiler, 2026-09-22).
def private inline_by_llvm(prog : ProgramPtr; mod : Module?) : bool {
    for_each_function(mod, "") $(var fn : FunctionPtr) {
        if (fn.moreFlags.mustInline) {
            fn.moreFlags.mustInline = false
            if (!add_hint(fn, "alwaysinline")) {
                macro_sticky_error(prog, fn.at, "m3_exec_expand: the builtin `hint` annotation is missing")
            }
        }
    }
    return false
}

// C's d_m3OpAllArgs, spelled from the function being generated: the names bind
// at the use site, so the generated call passes the dispatcher's own parameters
// straight through.
def private argument_names(var fn : FunctionPtr; var names : array<string>) {
    for (arg in fn.arguments) {
        names |> push(string(arg.name))
    }
}

// C: ((IM3Operation)(* _pc))(_pc + 1, d_m3OpArgs), with the operation named
// instead of loaded from the word.
def private build_op_call(at : LineInfo; name : string; argNames : array<string>) : ExpressionPtr {
    var call = new ExprCall(at = at, name := name)
    for (argName in argNames) {
        var argExpr = new ExprVar(at = at, name := argName)
        emplace(call.arguments, argExpr)
    }
    return new ExprReturn(at = at, subexpr = call)
}

// The leaf of either tree: the operation CALLED (m3_DispatchOp) or its function
// VALUE returned (m3_OpAt), because the two are the same shape over the same
// names.
def private build_op_leaf(at : LineInfo; name : string; argNames : array<string>; direct : bool) : ExpressionPtr {
    if (direct) return build_op_call(at, name, argNames)
    // C has no counterpart: @@op_<name> is the IM3Operation value the compile
    // tables of m3_compile.das hold, indexed the same way.
    var opAddr = new ExprAddr(at = at, target := name)
    return new ExprReturn(at = at, subexpr = opAddr)
}

// The balanced tree over [lo, hi): one leaf per operation, otherwise
// `if (idx < mid) { left } else { right }` around the halves.
def private build_op_tree(at : LineInfo; names : array<string>; lo : int; hi : int; direct : bool; argNames : array<string>) : ExpressionPtr {
    if (hi - lo == 1) return build_op_leaf(at, names[lo], argNames, direct)
    let mid = (lo + hi) / 2
    var cond = new ExprOp2(at = at, op := "<",
        left = new ExprVar(at = at, name := "idx"),
        right = new ExprConstInt(at = at, value = mid))
    var ifTrue = new ExprBlock(at = at)
    var lowHalf = build_op_tree(at, names, lo, mid, direct, argNames)
    emplace(ifTrue.list, lowHalf)
    var ifFalse = new ExprBlock(at = at)
    var highHalf = build_op_tree(at, names, mid, hi, direct, argNames)
    emplace(ifFalse.list, highHalf)
    return new ExprIfThenElse(at = at, cond = cond, if_true = ifTrue, if_false = ifFalse)
}

// The linear chain: one `if (idx == k) { return op_k (...) }` per operation in
// index order, the last operation as the fall-through, which is what LLVM folds
// into a switch with a jump table.
def private build_op_chain_into(at : LineInfo; names : array<string>; argNames : array<string>; var body : ExprBlock?) {
    for (i in range(length(names) - 1)) {
        var cond = new ExprOp2(at = at, op := "==",
            left = new ExprVar(at = at, name := "idx"),
            right = new ExprConstInt(at = at, value = i))
        var ifTrue = new ExprBlock(at = at)
        var leaf = build_op_leaf(at, names[i], argNames, true)
        emplace(ifTrue.list, leaf)
        var branch : ExpressionPtr = new ExprIfThenElse(at = at, cond = cond, if_true = ifTrue)
        emplace(body.list, branch)
    }
    var last = build_op_leaf(at, names[length(names) - 1], argNames, true)
    emplace(body.list, last)
}

// `let idx = m3_WordIndex (<pc>)`, the `(* _pc)` and the `_pc + 1` of C's
// nextOpImpl macro, ahead of the dispatch that consumes `idx`.
def private build_word_index(at : LineInfo; pcName : string) : ExpressionPtr {
    var call = new ExprCall(at = at, name := "m3_WordIndex")
    var pcArg = new ExprVar(at = at, name := pcName)
    emplace(call.arguments, pcArg)
    var bind = new ExprLet(at = at, atInit = at)
    var idxVar = new Variable(at = at, name := "idx",
        _type <- new TypeDecl(baseType = Type.autoinfer, at = at),
        init <- call,
        flags = VariableFlags.can_shadow | VariableFlags.generated)
    emplace(bind.variables, idxVar)
    return bind
}

// Replace a placeholder body by `body`, exactly where the placeholder stood.
def private set_body(var fn : FunctionPtr; var body : ExprBlock?) {
    fn.body = body
    fn.not_inferred()
}

def private set_body_stmt(var fn : FunctionPtr; var stmt : ExpressionPtr) {
    var body = new ExprBlock(at = fn.at)
    emplace(body.list, stmt)
    set_body(fn, body)
}

// `[hint(<name>)]` on a function (noinline on an operation, alwaysinline on a
// helper), added here rather than written in m3_exec.das because it is
// meaningful to the JIT alone and the other tiers must compile the source form
// untouched.
def private add_hint(var fn : FunctionPtr; name : string) : bool {
    var builtin = find_compiling_module("$")
    if (builtin == null) return false
    var hint = module_find_annotation(builtin, "hint")
    if (hint == null) return false
    var decl = new AnnotationDeclaration(uninitialized)
    decl.annotation = hint
    let argIdx = decl.arguments |> add_annotation_argument(name)
    decl.arguments[argIdx].basicType = Type.tBool
    decl.arguments[argIdx].bValue = true
    add_function_annotation(fn, decl)
    return true
}

//! Generates the direct-call dispatch of m3_exec - m3_DispatchOp, m3_OpAt and
//! m3_OpCount - so a code-page word can be an operation index instead of the
//! IM3Operation value C stores there. Runs under the LLVM JIT only.
class M3ExecDispatchPass : AstPassMacro {
    // Run-once, the same flag pattern and the same reason as M3ExecExpandPass
    // above: the generated bodies must be inferred, not regenerated.
    generated : bool = false

    def override apply(prog : ProgramPtr; mod : Module?) : bool {
        // The operations live in m3_exec; every other module compiles
        // untouched. And the C form is the source form, so the pass runs under
        // the LLVM JIT alone - the daslang interpreter, the -aot emission and
        // the -ctx emission compile m3_exec.das exactly as written.
        if (mod.name != "m3_exec" || generated || !prog.policies.jit_enabled) return false
        generated = true
        let shape = dispatch_shape(prog)
        // the two properties are orthogonal: the jump table and whether LLVM
        // may inline an operation into the dispatch
        let noinline = shape == "noinline" || shape == "chain_noinline"
        let chain = shape == "chain" || shape == "chain_noinline"
        var names : array<string>
        var anyAt = LineInfo()
        for_each_function(mod, "") $(var fn : FunctionPtr) {
            anyAt = fn.at
            // every operation is `def public op_<name> (d_m3OpSig)`, and the
            // five parameters are what tells one apart from any other op_ name
            if ((fn.name |> starts_with("op_")) && length(fn.arguments) == 5) {
                names |> push(string(fn.name))
                if (noinline) {
                    add_hint(fn, "noinline")
                }
            }
        }
        // byte order, so the numbering is a function of the source alone
        names |> sort()
        if (empty(names)) {
            macro_sticky_error(prog, anyAt,
                "m3_exec_expand: m3_exec declares no op_* operation, so there is nothing to dispatch")
            return false
        }
        var ok = true
        var seen = 0
        for_each_function(mod, "m3_DispatchOp") $(var fn : FunctionPtr) {
            seen++
            var argNames : array<string>
            argument_names(fn, argNames)
            var body = new ExprBlock(at = fn.at)
            var idxBind = build_word_index(fn.at, argNames[0])
            emplace(body.list, idxBind)
            if (chain) {
                build_op_chain_into(fn.at, names, argNames, body)
            } else {
                var tree = build_op_tree(fn.at, names, 0, length(names), true, argNames)
                emplace(body.list, tree)
            }
            set_body(fn, body)
        }
        for_each_function(mod, "m3_OpAt") $(var fn : FunctionPtr) {
            seen++
            // always the tree: m3_OpAt runs once, when m3_OpIndex fills its
            // reverse map, and never on the execution path
            let noArgs : array<string>
            var tree = build_op_tree(fn.at, names, 0, length(names), false, noArgs)
            set_body_stmt(fn, tree)
        }
        for_each_function(mod, "m3_OpCount") $(var fn : FunctionPtr) {
            seen++
            var count = new ExprConstInt(at = fn.at, value = length(names))
            var ret : ExpressionPtr = new ExprReturn(at = fn.at, subexpr = count)
            set_body_stmt(fn, ret)
        }
        // C: EmitWord (page, op) stores the IM3Operation value; the index
        // stands in for it, and this is the single site that spells the word.
        for_each_function(mod, "m3_OpWord") $(var fn : FunctionPtr) {
            seen++
            var call = new ExprCall(at = fn.at, name := "m3_OpIndex")
            var opArg = new ExprVar(at = fn.at, name := string(fn.arguments[0].name))
            emplace(call.arguments, opArg)
            var ret : ExpressionPtr = new ExprReturn(at = fn.at, subexpr = call)
            set_body_stmt(fn, ret)
        }
        // C: ((IM3Operation)(* _pc))(_pc + 1, d_m3OpArgs) — m3_DispatchOp reads
        // the word and advances the pc itself, so both macros become one call.
        for_each_function(mod, "nextOpImpl") $(var fn : FunctionPtr) {
            seen++
            var argNames : array<string>
            argument_names(fn, argNames)
            var stmt = build_op_call(fn.at, "m3_DispatchOp", argNames)
            set_body_stmt(fn, stmt)
        }
        for_each_function(mod, "jumpOpImpl") $(var fn : FunctionPtr) {
            seen++
            var argNames : array<string>
            argument_names(fn, argNames)
            var stmt = build_op_call(fn.at, "m3_DispatchOp", argNames)
            set_body_stmt(fn, stmt)
        }
        if (seen != 6) {
            macro_sticky_error(prog, anyAt,
                "m3_exec_expand: m3_exec must declare the six dispatch placeholders m3_DispatchOp, m3_OpAt, m3_OpCount, m3_OpWord, nextOpImpl and jumpOpImpl, found {seen}")
            ok = false
        }
        return ok
    }
}

// An `[infer_macro]` registration, spelled out so the module needs daslib/ast
// alone. Was `add_new_pre_infer_macro`: the pre-infer stage came out upstream
// (see the class comment above), and an infer-macro pass that keeps its own
// once-flag replaces the old gated pre-infer registration. See the require
// comment at the top.
[_macro]
def private setup() {
    if (is_compiling_macros_in_module("m3_exec_expand")) {
        add_new_infer_macro("m3_exec_expand", new M3ExecExpandPass())
        add_new_infer_macro("m3_exec_dispatch", new M3ExecDispatchPass())
    }
}

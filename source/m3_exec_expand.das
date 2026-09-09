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
    (notes/interp_node_cost_2026-09-08.md), and an operation that reads two
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
        var expander = new ExpandReaders()
        expander.prog := prog
        var ok = true
        for_each_function(mod, "") $(var fn : FunctionPtr) {
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

// An `[infer_macro]` registration, spelled out so the module needs daslib/ast
// alone. Was `add_new_pre_infer_macro`: the pre-infer stage came out upstream
// (see the class comment above), and an infer-macro pass that keeps its own
// once-flag replaces the old gated pre-infer registration. See the require
// comment at the top.
[_macro]
def private setup() {
    if (is_compiling_macros_in_module("m3_exec_expand")) {
        add_new_infer_macro("m3_exec_expand", new M3ExecExpandPass())
    }
}

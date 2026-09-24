options gen2

// Same shape as tests-cpp/big/standalone_module_global, but with the configuration
// in the entry module instead of a required one. RC2's -ctx *does* generate this
// one, which is what makes it usable to isolate the second blocker: the generated
// constructor calls das::InitGlobalVar(Context&, GlobalVariable*, GlobalVarInfo)
// by value, and the shipped runtime library only defines the const& overload.

struct Limits {
    retries : int
    timeout_ms : int
}

var g_limits = Limits(retries = 3, timeout_ms = 250)
var g_total_budget_ms = g_limits.retries * g_limits.timeout_ms

[export]
def get_retries : int {
    return g_limits.retries
}

[export]
def get_total_budget_ms : int {
    return g_total_budget_ms
}

options gen2

module standalone_module_global_dep public

// The configuration a library module owns and initializes for its embedders.

struct Limits {
    retries : int
    timeout_ms : int
}

var g_limits = Limits(retries = 3, timeout_ms = 250)
var g_backoff = fixed_array(10, 40, 160)
var g_service_name = "ingest"

def public limits : Limits {
    return g_limits
}

def public backoff_at(attempt : int) : int {
    return attempt < length(g_backoff) ? g_backoff[attempt] : g_backoff[length(g_backoff) - 1]
}

def public service_name : string {
    return g_service_name
}

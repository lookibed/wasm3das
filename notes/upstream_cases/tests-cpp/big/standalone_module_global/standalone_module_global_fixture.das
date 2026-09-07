options gen2

require standalone_module_global_dep

// The entry module reads the required module's initialized globals. This is the
// ordinary shape of a library module that owns its configuration, and it has to
// survive -ctx generation, compilation and linking.

var g_total_budget_ms = limits().retries * limits().timeout_ms

[export]
def get_retries : int {
    return limits().retries
}

[export]
def get_total_budget_ms : int {
    return g_total_budget_ms
}

[export]
def get_backoff(attempt : int) : int {
    return backoff_at(attempt)
}

[export]
def service_name_length : int {
    return length(service_name())
}

// So the same file can be checked by the plain interpreter and by -aot, not only
// through the generated context.
[export]
def main {
    var failures = 0
    if (get_retries() != 3) {
        failures ++
    }
    if (get_total_budget_ms() != 750) {
        failures ++
    }
    if (get_backoff(0) != 10 || get_backoff(1) != 40 || get_backoff(7) != 160) {
        failures ++
    }
    if (service_name_length() != 6) {
        failures ++
    }
    if (failures != 0) {
        panic("standalone_module_global: {failures} check(s) failed")
    }
    print("standalone_module_global: PASSED\n")
}

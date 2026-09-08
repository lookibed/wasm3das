// Minimal host that links the generated standalone context of samefile_global.das.
#include "daScript/misc/platform.h"
#include "daScript/daScript.h"
#include "samefile_global.das.h"

using namespace das;

int main() {
    samefile_global::Standalone ctx;
    TextPrinter tout;
    int failures = 0;
    if (ctx.get_retries() != 3) { tout << "get_retries() = " << ctx.get_retries() << "\n"; failures++; }
    if (ctx.get_total_budget_ms() != 750) { tout << "get_total_budget_ms() = " << ctx.get_total_budget_ms() << "\n"; failures++; }
    if (!failures) { tout << "samefile_global: PASSED\n"; }
    return failures ? 1 : 0;
}

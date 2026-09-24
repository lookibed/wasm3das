#include "daScript/daScript.h"
#include "standalone_module_global_fixture.das.h"

using namespace das;

int main( int, char * [] ) {
    standalone_module_global_fixture::Standalone ctx;
    TextPrinter tout;
    int failures = 0;
    auto expect = [&]( const char * name, int32_t have, int32_t want ) {
        if ( have != want ) {
            tout << name << " = " << have << ", expected " << want << "\n";
            failures ++;
        }
    };
    // the required module's initialized globals have to be live in the context
    expect("get_retries()", ctx.get_retries(), 3);
    expect("get_total_budget_ms()", ctx.get_total_budget_ms(), 750);
    expect("get_backoff(0)", ctx.get_backoff(0), 10);
    expect("get_backoff(1)", ctx.get_backoff(1), 40);
    expect("get_backoff(7)", ctx.get_backoff(7), 160);
    expect("service_name_length()", ctx.service_name_length(), 6);
    return failures ? 1 : 0;
}

// Host stub for the -ctx generated wasm3 standalone context.
// Port of platforms/app/main.c through the -ctx emitter: the compiled program
// lives in the generated wasm3.das.cpp/.h, so the host is only a stand-in for
// the role the daslang CLI plays in the interpreted run — it hands the
// command line over and calls main.
//
// The app reads its arguments with get_command_line_arguments() and skips
// until a literal "--" (the spelling the daslang CLI feeds it: `daslang
// app.das -- <args>`), so the stub prepends a "--" to the process arguments.
//
// The program runs on a thread with its own 256 MiB stack. The port has no
// M3_MUSTTAIL: ops return to the RunLoop dispatcher, but every wasm call
// still nests native frames, and the app's daslang context stack (`options
// stack`) sits on top. With the default 8 MiB main-thread stack an unbounded
// wasm recursion kills the process with SIGSEGV before op_Entry can report
// `[trap] stack overflow`, which the spec suite's assert_exhaustion cases
// expect. The launchers raise `ulimit -s` for that; a shipped standalone
// binary has no launcher, so it reserves the stack itself, on every
// platform, and needs neither ulimit nor a PE header edit. 256 MiB is the
// same figure the launchers use (`ulimit -s 262144`); the reservation costs
// no memory until touched.

#include "wasm3.das.h"
#include <vector>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

namespace {

const size_t kStackBytes = size_t(256) * 1024 * 1024;

int g_argc = 0;
char ** g_argv = nullptr;
int g_rc = 1;

void run_main() {
    std::vector<char *> args;
    args.push_back(const_cast<char *>("--"));
    for (int i = 1; i < g_argc; ++i) {
        args.push_back(g_argv[i]);
    }
    das::setCommandLineArguments(int(args.size()), args.data());
    das::wasm3::Standalone ctx;
    g_rc = ctx.main();
}

#ifdef _WIN32
DWORD WINAPI thread_entry(LPVOID) {
    run_main();
    return 0;
}
#else
void * thread_entry(void *) {
    run_main();
    return nullptr;
}
#endif

}  // namespace

int main(int argc, char * argv[]) {
    g_argc = argc;
    g_argv = argv;
#ifdef _WIN32
    HANDLE h = CreateThread(nullptr, kStackBytes, thread_entry, nullptr,
                            STACK_SIZE_PARAM_IS_A_RESERVATION, nullptr);
    if (h == nullptr) {
        run_main();  // no thread: the main-thread stack, as before
        return g_rc;
    }
    WaitForSingleObject(h, INFINITE);
    CloseHandle(h);
#else
    pthread_attr_t attr;
    pthread_t thread;
    if (pthread_attr_init(&attr) != 0
        || pthread_attr_setstacksize(&attr, kStackBytes) != 0
        || pthread_create(&thread, &attr, thread_entry, nullptr) != 0) {
        run_main();  // no thread: the main-thread stack, as before
        return g_rc;
    }
    pthread_join(thread, nullptr);
    pthread_attr_destroy(&attr);
#endif
    return g_rc;
}

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
// M3_MUSTTAIL: the emitted `return operation(...)` at the end of every
// operation is a tail jump only where the C++ compiler makes it one, every
// wasm call still nests native frames, and the app's daslang context stack
// (`options stack`) sits on top. With the default 8 MiB main-thread stack an unbounded
// wasm recursion kills the process with SIGSEGV before op_Entry can report
// `[trap] stack overflow`, which the spec suite's assert_exhaustion cases
// expect. The launchers raise `ulimit -s` for that; a shipped standalone
// binary has no launcher, so it reserves the stack itself, on every
// platform, and needs neither ulimit nor a PE header edit. 256 MiB is the
// same figure the launchers use (`ulimit -s 262144`); the reservation costs
// no memory until touched.

#include "wasm3.das.h"
#include <cstdio>
#include <cstdlib>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <process.h>   // _exit
#else
#include <pthread.h>
#include <unistd.h>    // _exit
#endif
#ifdef __GLIBC__
#include <malloc.h>
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
    // The emitter's C entry points (daslang 0.6.4 after the pin): an instance
    // is created with its global initializers run, the exported `main` is
    // called on it, and an exception in either shows up as a non-NULL
    // wasm3_last_error instead of a C++ throw.
    wasm3_ctx * ctx = wasm3_create();
    if (ctx == nullptr) {
        const char * err = wasm3_last_error(nullptr);
        std::fprintf(stderr, "wasm3: %s\n", err != nullptr ? err : "context creation failed");
        g_rc = 1;
        return;
    }
    g_rc = int(wasm3_main(ctx));
    const char * err = wasm3_last_error(ctx);
    if (err != nullptr) {
        std::fprintf(stderr, "wasm3: %s\n", err);
        g_rc = 1;
    }
    // The teardown (the context's destructor and the module registry's
    // shutdown behind it) costs about a fifth of a start and frees memory
    // the process is about to give back anyway; the C wasm3 has nothing to
    // tear down at this point. The default is to leave through _exit with
    // the streams flushed. WASM3DAS_TEARDOWN=1 runs the full teardown: for
    // the ASan and leak-check builds, which need every destructor.
    if (std::getenv("WASM3DAS_TEARDOWN") == nullptr) {
        std::fflush(stdout);
        std::fflush(stderr);
        _exit(g_rc);
    }
    wasm3_destroy(ctx);
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
#ifdef __GLIBC__
    // The program runs on a second thread, so glibc would serve its
    // allocations from a per-thread arena that grows by mprotect'ing one
    // page group at a time: about 3100 mprotect calls during the module
    // registration of a start (strace -c). One arena keeps every allocation
    // on the brk heap, which grows in the larger steps M_TOP_PAD asks for.
    mallopt(M_ARENA_MAX, 1);
    mallopt(M_TOP_PAD, 64 * 1024 * 1024);
#endif
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

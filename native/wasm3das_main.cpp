// Native host for the Daslang port of wasm3.
//
// The port stays Daslang source, but its functions are AOT-compiled to C++
// (daslang -aot, one translation unit per module) and linked into this
// binary together with libDaScript. At startup app/wasm3.das is still
// parsed and type-checked (AOT swaps the interpreter nodes for the native
// functions during simulate; a standalone context with zero startup is not
// yet supported by the pinned toolchain for this code base), then main() of
// the app runs natively. Modelled on utils/mcp/cpp_mcp_main.cpp of daslang.
//
// Layout: the binary lives in <root>/bin, daslib in <root>/daslib and the
// app in <root>/app/wasm3.das (the release bundle layout). `-dasroot <dir>`
// overrides the root; the words after the options reach the app as its
// argv exactly as `daslang app/wasm3.das -- <args>` would pass them.

#include "daScript/daScript.h"
#include "daScript/daScriptModule.h"
#include "daScript/misc/das_common.h"     // SimulateWithErrReport
#include "daScript/misc/crash_handler.h"  // install_das_crash_handler

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace das;

static bool file_exists(const string & p) {
    FILE * f = fopen(p.c_str(), "rb");
    if ( f ) { fclose(f); return true; }
    return false;
}

int main(int argc, char * argv[]) {
    install_das_crash_handler();

    // -dasroot <dir> is consumed here; everything else goes to the app after
    // a `--` separator, which app/wasm3.das's process_argv looks for.
    // -no-aot runs the app in the interpreter (a diagnostic switch), -aot-strict
    // makes the startup fail with a report when a function has no AOT code.
    bool useAot = true;
    bool strictAot = false;
    std::vector<char *> appArgs;
    appArgs.push_back(argv[0]);
    appArgs.push_back(const_cast<char *>("--"));
    for ( int i = 1; i < argc; ++i ) {
        if ( strcmp(argv[i], "-dasroot") == 0 && i + 1 < argc ) {
            setDasRoot(argv[i + 1]);
            ++i;
            continue;
        }
        if ( strcmp(argv[i], "-no-aot") == 0 ) { useAot = false; continue; }
        if ( strcmp(argv[i], "-aot-strict") == 0 ) { strictAot = true; continue; }
        appArgs.push_back(argv[i]);
    }
    setCommandLineArguments(int(appArgs.size()), appArgs.data());

    string appPath = getDasRoot() + "/app/wasm3.das";
    if ( !file_exists(appPath) ) {
        fprintf(stderr, "wasm3das: app/wasm3.das not found under %s (use -dasroot <bundle root>)\n", getDasRoot().c_str());
        return 1;
    }

    register_builtin_modules();
    Module::Initialize();

    int rc = 1;
    {
        TextPrinter tout;
        auto access = make_smart<FsFileAccess>();
        ModuleGroup dummyGroup;

        CodeOfPolicies policies;
        policies.aot = useAot;                      // link the AOT functions during simulate
        policies.fail_on_no_aot = strictAot;        // otherwise a function without AOT falls back to the interpreter
        policies.fail_on_lack_of_aot_export = false;

        auto program = compileDaScript(appPath, access, tout, dummyGroup, policies);
        if ( program && !program->failed() ) {
            auto pctx = SimulateWithErrReport(program, tout);
            if ( pctx ) {
                if ( auto fnMain = pctx->findFunction("main") ) {
                    pctx->restart();
                    vec4f result = pctx->evalWithCatch(fnMain, nullptr);
                    if ( auto ex = pctx->getException() ) {
                        tout << "EXCEPTION: " << ex << "\n";
                    } else {
                        rc = cast<int32_t>::to(result);
                    }
                } else {
                    tout << "app/wasm3.das: main() not found\n";
                }
            }
        } else if ( program ) {
            for ( auto & err : program->errors ) {
                tout << reportError(err.at, err.what, err.extra, err.fixme, err.cerr);
            }
        }
    }
    Module::Shutdown();
    return rc;
}

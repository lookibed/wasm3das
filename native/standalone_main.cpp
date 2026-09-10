// Scratch host stub for the -ctx generated wasm3 standalone context.
// Port of platforms/app/main.c through the -ctx emitter: the compiled program
// lives in the generated wasm3.das.cpp/.h, so the host is only a stand-in for
// the role the daslang CLI plays in the interpreted run — it hands the
// command line over and calls main.
//
// The app reads its arguments with get_command_line_arguments() and skips
// until a literal "--" (the spelling the daslang CLI feeds it: `daslang
// app.das -- <args>`), so the stub prepends a "--" to the process arguments.
// Experimented into existence in tmp/ during the -ctx investigation; landed
// when the pin moved past the standalone-emission fixes (scripts/daslang_pin).

#include "wasm3.das.h"
#include <vector>

int main(int argc, char * argv[]) {
    std::vector<char *> args;
    args.push_back(const_cast<char *>("--"));
    for (int i = 1; i < argc; ++i) {
        args.push_back(argv[i]);
    }
    das::setCommandLineArguments(int(args.size()), args.data());
    das::wasm3::Standalone ctx;
    return ctx.main();
}

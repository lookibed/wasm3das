// Proof that the by-value/const& mismatch of InitGlobalVar is the ONLY link
// blocker on v0.6.4-RC2: include/daScript/simulate/standalone_ctx_utils.h declares
//   void InitGlobalVar(Context &, GlobalVariable *, GlobalVarInfo);        // by value
// while lib/liblibDaScript_runtime.a defines only
//   void InitGlobalVar(Context &, GlobalVariable *, const GlobalVarInfo &);
// This defines the by-value overload the generated context calls and forwards it to
// the const& symbol the library actually exports (asm label = the exact mangling).
#include "daScript/misc/platform.h"
#include "daScript/simulate/standalone_ctx_utils.h"

namespace das {
    void InitGlobalVar_realConstRef(Context &ctx, GlobalVariable *gvar, const GlobalVarInfo &info)
        asm("_ZN3das13InitGlobalVarERNS_7ContextEPNS_14GlobalVariableERKNS_13GlobalVarInfoE");

    void InitGlobalVar(Context &ctx, GlobalVariable *gvar, GlobalVarInfo info) {
        InitGlobalVar_realConstRef(ctx, gvar, info);
    }
}

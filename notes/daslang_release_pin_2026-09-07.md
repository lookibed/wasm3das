# Switching the toolchain to the official daslang release bundle

Date: 2026-09-07. Owner's decision: wasm3das uses only the prebuilt daslang
release bundle from `GaijinEntertainment/daScript`, everywhere, including
the gate and CI. daslang is neither built from source nor patched for this
project any more.

## What changed

- `scripts/daslang_release.env` pins the release: tag `v0.6.4-RC2`
  (2026-08-19) and the sha256 of each `daslang-bundle-<platform>.zip`
  (linux-x86_64, linux-arm64, windows-x86_64, darwin26-arm64).
- `scripts/install_daslang.sh` downloads the asset for the current (or the
  given) platform, verifies the checksum, unpacks it into `tmp/daslang` and
  writes the stamp `tmp/daslang/.wasm3das-release` (`<tag> <platform>`).
- `scripts/gate.sh` refuses to run unless that stamp carries the pinned tag
  (`DASLANG_ALLOW_UNPINNED=1` bypasses it for local experiments only) and
  prints the release it runs on. `.githooks/pre-push`,
  `scripts/check_repo_invariants.sh`, `scripts/wasm3`,
  `scripts/build_native.sh`, `scripts/bench.sh` and
  `tests/manual/run_fixtures.py` default to `tmp/daslang`.
- `.github/workflows/daslang-quality.yml` installs the bundle through the
  same script (cached by tag and sha256) instead of cloning and building a
  commit; `release.yml` does the same per platform and no longer needs CMake
  or a compiler. `scripts/make_release_bundle.sh` ships the dynamically
  linked release binary with its `libDaScriptDyn*` beside it (`lib/` on
  Linux, `bin/*.dll` on Windows).
- `.mcp.json` and the LSP plugin run the bundle's `utils/mcp` and
  `utils/lsp`; the DAP bridge still comes from the `tmp/daslang-dap`
  worktree of PR #3937 (the release has no `utils/dap`), with the release
  binary as the debuggee.
- The self-built `tmp/daslang-toolchain` (commit `1524b3bf`, 2026-08-10) and
  the `tmp/daslang-jit` worktree are no longer referenced by anything.

Why: the self-built toolchain had drifted into four cmake configurations of
one commit, its MCP server stopped working because the dynamic modules it
required were never built, and the JIT existed only as an unpinned worktree
with uncommitted patches. The release bundle is one reproducible artefact
that the daslang maintainers ship and test.

## Verification on v0.6.4-RC2 (linux-x86_64)

- `scripts/gate.sh`: compile, paranoid/perf/style lint, dastest 123/123
  (the spec corpus is present locally, so `test_spec_core` and
  `test_spec_modules_load` ran), invariants.
- The newer `perf_lint` of the release reported two `PERF031` findings in
  `app/wasm3.das` (`slice` of a loop-invariant string inside a loop) that
  the 2026-08-10 build did not have. Fixed in the port: `modname_from_fn`
  advances a start offset over one byte view and slices once after the
  separator loop (C advances the `fn` pointer per `strrchr`); `split_argv`
  slices the `peek_data` view of the line instead of the line itself.
  Behaviour is unchanged (`--func`, the REPL and the WASI argv path were
  re-run).
- `scripts/build_native.sh` builds against the bundle's `include/` and
  static libraries without the source checkout's `3rdparty/` headers.
- `wasm3c/test/run-spec-test.py` (default list) through `scripts/wasm3
  --repl`: 17863/17863, 0 crashes, 0 timeouts; the same through
  `scripts/wasm3-native --repl`: 17863/17863.
- `wasm3c/test/run-wasi-test.py --fast` through `scripts/wasm3`: 7/7; through
  `scripts/wasm3-native`: 7/7.

## Known differences of the release from the old pinned commit

- **`-jit` crashes on the port.** `daslang app/wasm3.das -jit` (also
  `-jit-no-cache`, `-jit-stack`, `-exe`, `-dry-run`) dies with SIGSEGV
  during LLVM code generation, before the `LLVM JIT: N functions` line, as
  soon as `source/m3_compile.das` is in the program; `m3_core`, `m3_types`
  and `m3_exec` alone pass. The 2026-08-10 build with the local patch
  `notes/daslang_jit_fixes_2026-09-07.patch` generated code but computed
  wrong results. The likely cause is the unpatched qualified-intrinsic-name
  bug of dasLLVM (`math::sqrt` → `llvm.math::sqrt.f32`, intrinsic id 0,
  null dereference), which the port reaches through `math::sqrt`,
  `math::ceil`, `math::floor` and `math::trunc` in the `op_*` bodies; not
  confirmed by a debugger run. The JIT rows of `scripts/bench.sh` and the
  jit column of `tests/manual/run_fixtures.py` therefore fail on this
  release. This is a daslang bug to report upstream with `tmp/jitprobe`-style
  reproducers, not something to work around in the port.
- **DAP debuggee.** `test_mcp_bridge.py::test_waiting_worker_shutdown`
  fails with the release binary (SIGSEGV when a waiting debugger worker is
  cancelled); PR #3937 fixed it upstream after the release. Documented in
  `AGENTS.md`.
- **Standalone context (`-ctx`).** Unchanged: the release predates the
  upstream fixes (PR #3838 and later), so `utils/aot/main.das -ctx` still
  fails on a used global of a required module.

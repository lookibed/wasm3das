<!-- Title = squash commit subject: state the proven invariant or the C comparison. -->

## Type

<!-- port / promote / runtime-fix / docs / ci — see docs/development-pipeline.md -->

## Scope

<!-- What changed, in one paragraph. For a series: "<document> step N/M". -->

## Deferred

<!-- What was intentionally left out and why. -->

## C references

<!-- wasm3c/source/<file>.c:<lines> for every function touched. -->

## Verification

<!-- Gate summary: compile N/N, lint 0/0/0, dastest N/N.
     Runtime changes: fib32 result and teardown outcome; DAP evidence as text. -->

## Manifest transition

<!-- <layer>: <old status> → <new status>, or "none". Accepted is the owner's call. -->

## Self-review against C

- [ ] names, order and control flow match the C source
- [ ] allocator pair correct for every pointer
- [ ] pointer-array vs struct-array indexing checked at every `addr(...)`
- [ ] every C macro expanded, not called
- [ ] every deviation documented at the site
- [ ] no mass regex or script rewrite
- [ ] `.lint_config` unchanged

<!-- promote PRs only: one row per C function, in C order.
| C function | Daslang function | Deviation and where it is documented |
|---|---|---|
-->

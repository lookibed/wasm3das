# real-world-binjgb fixture

Upstream: [binjgb](https://github.com/binji/binjgb) - MIT
(C) 2016 Ben Smith.
Module glue: Spider (AGPL-3.0). The canonical ROM `cgb-acid2.gbc` was
embedded into the module at build time as a byte array; no commercial
ROM bytes are present.


## Origin

Fixture taken from the [Spider](https://github.com/lookibed/Spider) project
(upstream: https://github.com/SovereignSatellite/Spider), folder
`tests/manual/real-world-binjgb/generated/`. Spider itself is licensed under AGPL-3.0;
the wasm module glue (`module.c`, `shim.c`) is Spider's work and is AGPL-3.0.

This copy contains only the compiled `.wasm` module; see the Spider
repository for build sources and harnesses.

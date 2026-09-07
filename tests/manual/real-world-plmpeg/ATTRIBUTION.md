# real-world-plmpeg fixture

Upstream: [PL_MPEG](https://github.com/phoboslab/pl_mpeg) - MIT
(SPDX-License-Identifier: MIT in pl_mpeg.h).
Module glue: Spider (AGPL-3.0). The canonical `sample.m1v` clip is
embedded in the module; the real-file host path needs the fixture from
the Spider repository.


## Origin

Fixture taken from the [Spider](https://github.com/lookibed/Spider) project
(upstream: https://github.com/SovereignSatellite/Spider), folder
`tests/manual/real-world-plmpeg/generated/`. Spider itself is licensed under AGPL-3.0;
the wasm module glue (`module.c`, `shim.c`) is Spider's work and is AGPL-3.0.

This copy contains only the compiled `.wasm` module; see the Spider
repository for build sources and harnesses.

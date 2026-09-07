# real-world-lodepng fixture

Upstream: [LodePNG](https://github.com/lvandeve/lodepng) - zlib-style license
(C) 2005-2018 Lode Vandevenne.
Module glue: Spider (AGPL-3.0). The test image is generated
deterministically in the module; no PNG fixture file is required.


## Origin

Fixture taken from the [Spider](https://github.com/lookibed/Spider) project
(upstream: https://github.com/SovereignSatellite/Spider), folder
`tests/manual/real-world-lodepng/generated/`. Spider itself is licensed under AGPL-3.0;
the wasm module glue (`module.c`, `shim.c`) is Spider's work and is AGPL-3.0.

This copy contains only the compiled `.wasm` module; see the Spider
repository for build sources and harnesses.

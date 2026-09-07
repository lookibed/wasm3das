# real-world-miniz-file fixture

Upstream: [miniz](https://github.com/richgel999/miniz) - MIT
(C) 2013-2014 RAD Game Tools and Valve Software;
(C) 2010-2014 Rich Geldreich and Tenacious Software LLC.
Module glue and virtual-stdio shim: Spider (AGPL-3.0).


## Origin

Fixture taken from the [Spider](https://github.com/lookibed/Spider) project
(upstream: https://github.com/SovereignSatellite/Spider), folder
`tests/manual/real-world-miniz-file/generated/`. Spider itself is licensed under AGPL-3.0;
the wasm module glue (`module.c`, `shim.c`) is Spider's work and is AGPL-3.0.

This copy contains only the compiled `.wasm` module; see the Spider
repository for build sources and harnesses.

# real-world-libjpeg-turbo fixture

Upstream: [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo)
- BSD-style license (IJG-compatible). Module glue: Spider (AGPL-3.0).
The canonical `sample.jpg` is embedded in the module as a byte array.


## Origin

Fixture taken from the [Spider](https://github.com/lookibed/Spider) project
(upstream: https://github.com/SovereignSatellite/Spider), folder
`tests/manual/real-world-libjpeg-turbo/generated/`. Spider itself is licensed under AGPL-3.0;
the wasm module glue (`module.c`, `shim.c`) is Spider's work and is AGPL-3.0.

This copy contains only the compiled `.wasm` module; see the Spider
repository for build sources and harnesses.

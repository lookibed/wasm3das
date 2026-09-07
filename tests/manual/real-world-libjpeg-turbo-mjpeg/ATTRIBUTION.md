# real-world-libjpeg-turbo-mjpeg fixture

Upstream: [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo)
- BSD-style license (IJG-compatible). Module glue: Spider (AGPL-3.0).
The canonical `sample.mjpg` stream is embedded in the module.


## Origin

Fixture taken from the [Spider](https://github.com/lookibed/Spider) project
(upstream: https://github.com/SovereignSatellite/Spider), folder
`tests/manual/real-world-libjpeg-turbo-mjpeg/generated/`. Spider itself is licensed under AGPL-3.0;
the wasm module glue (`module.c`, `shim.c`) is Spider's work and is AGPL-3.0.

This copy contains only the compiled `.wasm` module; see the Spider
repository for build sources and harnesses.

# real-world-h264bsd-mp4 fixture

Upstreams:
- [minimp4](https://github.com/lieff/minimp4) - public domain (CC0)
- [h264bsd](https://github.com/oneam/h264bsd) - Apache License 2.0
  (C) 2009 The Android Open Source Project
Module glue: Spider (AGPL-3.0). The canonical `sample.mp4` clip is
embedded in the module.


## Origin

Fixture taken from the [Spider](https://github.com/lookibed/Spider) project
(upstream: https://github.com/SovereignSatellite/Spider), folder
`tests/manual/real-world-h264bsd-mp4/generated/`. Spider itself is licensed under AGPL-3.0;
the wasm module glue (`module.c`, `shim.c`) is Spider's work and is AGPL-3.0.

This copy contains only the compiled `.wasm` module; see the Spider
repository for build sources and harnesses.

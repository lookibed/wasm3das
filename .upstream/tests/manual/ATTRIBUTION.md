# Attribution of the manual fixture modules

Every fixture directory under `tests/manual/` holds only a compiled `.wasm`
module taken from the [Spider](https://github.com/lookibed/Spider) project
(upstream: https://github.com/SovereignSatellite/Spider), folder
`tests/manual/<fixture>/generated/`. Spider is licensed under AGPL-3.0; the
wasm module glue (`module.c`, `shim.c`) is Spider's work and is AGPL-3.0. Build
sources and harnesses are in the Spider repository. Third-party code inside
the modules:

| fixture | third-party upstream | license | notes |
|---|---|---|---|
| `chipmunk-profile` | [Chipmunk2D](https://github.com/slembcke/Chipmunk2D), (C) 2007-2015 Scott Lembcke and Howling Moon Software | MIT | profiling module over Spider's glue |
| `fixtures` | none | AGPL-3.0 | `test.wasm`, a trivial smoke module |
| `float-compare` | none | AGPL-3.0 | float hash module from Spider's own C sources |
| `hash-compare` | none | AGPL-3.0 | hash loop module from Spider's own C sources |
| `i64-compare` | none | AGPL-3.0 | i64 hash/div module from Spider's own C sources |
| `real-archive-secret` | [miniz](https://github.com/richgel999/miniz), (C) 2013-2014 RAD Game Tools and Valve Software, (C) 2010-2014 Rich Geldreich and Tenacious Software LLC | MIT | the canonical `secretik.zip` is not needed by the scalar parity probes; expected text and CRC are embedded |
| `real-world-binjgb` | [binjgb](https://github.com/binji/binjgb), (C) 2016 Ben Smith | MIT | the ROM `cgb-acid2.gbc` is embedded as a byte array; no commercial ROM bytes |
| `real-world-chipmunk` | Chipmunk2D, as above | MIT | |
| `real-world-h264bsd-mp4` | [minimp4](https://github.com/lieff/minimp4) (public domain, CC0); [h264bsd](https://github.com/oneam/h264bsd), (C) 2009 The Android Open Source Project | CC0; Apache-2.0 | the `sample.mp4` clip is embedded |
| `real-world-libjpeg-turbo` | [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) | BSD-style (IJG-compatible) | `sample.jpg` embedded as a byte array |
| `real-world-libjpeg-turbo-mjpeg` | libjpeg-turbo, as above | BSD-style (IJG-compatible) | the `sample.mjpg` stream is embedded |
| `real-world-lodepng` | [LodePNG](https://github.com/lvandeve/lodepng), (C) 2005-2018 Lode Vandevenne | zlib-style | the test image is generated deterministically in the module |
| `real-world-miniz` | miniz, as above | MIT | |
| `real-world-miniz-file` | miniz, as above | MIT | virtual-stdio shim by Spider |
| `real-world-miniz-full` | miniz, as above | MIT | |
| `real-world-plmpeg` | [PL_MPEG](https://github.com/phoboslab/pl_mpeg) (SPDX MIT in `pl_mpeg.h`) | MIT | `sample.m1v` embedded; the real-file host path needs the fixture from the Spider repository |
| `real-world-plmpeg-stream` | PL_MPEG, as above | MIT | `sample.m1v` embedded |
| `real-world-tinyexpr` | [TinyExpr](https://github.com/codeplea/tinyexpr), (C) 2015, 2016 Lewis Van Winkle | zlib | standalone shim by Spider |
| `self-hosting-luanoffi-builder` | none | AGPL-3.0 | Rust wrapper crate built by Spider itself |

# Spider manual fixtures: parity and timing

| Тест | wasmtime | wasm3 C | wasm3das | wasm3das(jit) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `add` 1 2 | 0.007s | 0.001s | 1.985s | 10.851s | ~272x | ~1495x |
| `hash_loop` seed 123456789, 200000 итераций | 0.008s | 0.006s | 3.327s | 10.846s | ~427x | ~534x |
| `hash_loop` seed 1, 65536 итераций | 0.008s | 0.003s | 2.218s | 9.938s | ~294x | ~851x |
| `hash_f32` 2048 элементов | 0.008s | 0.002s | 1.891s | 9.834s | ~251x | ~1155x |
| `hash_f64` 2048 элементов | 0.008s | 0.001s | 1.910s | 9.723s | ~242x | ~1288x |
| `hash_i64_mix` 512 элементов | 0.010s | 0.001s | 1.873s | 9.658s | ~196x | ~1407x |
| `hash_i64_div` 512 элементов | 0.010s | 0.001s | 1.887s | 9.671s | ~198x | ~1343x |
| `probe_div_s64` | 0.010s | 0.001s | 1.898s | 9.821s | ~196x | ~1361x |
| `probe_rem_s64` | 0.010s | 0.001s | 1.895s | 9.791s | ~187x | ~1422x |
| `probe_div_u64` | 0.010s | 0.001s | 1.902s | 9.718s | ~196x | ~1348x |
| `probe_rem_u64` | 0.010s | 0.001s | 1.844s | 9.682s | ~192x | ~1413x |
| `tinyexpr_hash` 256 выражений | 0.024s | 0.003s | 2.039s | **✗ -1001** | ~86x | ~678x |
| `tinyexpr_error_code` | 0.023s | 0.002s | 1.852s | **✗ 1** | ~79x | ~1009x |
| `miniz_roundtrip_hash` уровень 6 | 0.039s | 0.005s | 2.434s | **✗ ERR** | ~62x | ~476x |
| `miniz_probe_compressed_size` уровень 6 | 0.042s | 0.004s | 2.264s | **✗ ERR** | ~54x | ~527x |
| `miniz_probe_crc32` | 0.042s | 0.002s | 1.961s | **✗ -101385738** | ~46x | ~793x |
| `miniz_probe_adler32` | 0.040s | 0.002s | 1.890s | 9.718s | ~47x | ~759x |
| `miniz_probe_fold_hash` | 0.040s | 0.002s | 1.957s | 9.709s | ~49x | ~794x |
| `miniz_full_hash` уровень 6 | 0.059s | 0.015s | 2.632s | **✗ ERR** | ~45x | ~176x |
| `miniz_full_num_files` уровень 6 | 0.049s | 0.009s | 2.655s | **✗ ERR** | ~54x | ~290x |
| `miniz_full_archive_size` уровень 6 | 0.050s | 0.009s | 2.654s | **✗ ERR** | ~53x | ~291x |
| `miniz_full_locate_mix` уровень 6 | 0.058s | 0.009s | 2.630s | **✗ ERR** | ~45x | ~292x |
| `miniz_full_extract_hash` уровень 6 | 0.059s | 0.009s | 2.611s | **✗ ERR** | ~44x | ~296x |
| `miniz_full_validate` уровень 6 | 0.051s | 0.008s | 2.604s | **✗ ERR** | ~51x | ~346x |
| `miniz_file_hash` уровень 6 | 0.068s | 0.011s | 2.825s | **✗ ERR** | ~41x | ~247x |
| `miniz_file_num_files` уровень 6 | 0.065s | 0.013s | 2.813s | **✗ ERR** | ~44x | ~219x |
| `miniz_file_archive_size` уровень 6 | 0.070s | 0.013s | 2.830s | **✗ ERR** | ~40x | ~215x |
| `miniz_file_extract_hash` уровень 6 | 0.066s | 0.013s | 2.859s | **✗ ERR** | ~43x | ~218x |
| `miniz_file_in_place` уровень 6 | 0.060s | 0.013s | 2.808s | **✗ ERR** | ~47x | ~213x |
| `lodepng_roundtrip` картинка 0 | 0.082s | 0.016s | 3.580s | **✗ -2029** | ~44x | ~221x |
| `lodepng_encoded_size` картинка 0 | 0.083s | 0.014s | 3.304s | **✗ 171240** | ~40x | ~244x |
| `lodepng_decode_hash` картинка 0 | 0.086s | 0.014s | 3.562s | **✗ -2029** | ~42x | ~258x |
| `lodepng_input_hash` картинка 0 | 0.083s | 0.007s | 1.894s | 9.668s | ~23x | ~270x |
| `lodepng_png_hash` картинка 0 | 0.083s | 0.014s | 3.304s | **✗ 221296935** | ~40x | ~234x |
| `lodepng_roundtrip` картинка 1 | 0.084s | 0.018s | 4.335s | **✗ -2029** | ~51x | ~240x |
| `lodepng_encoded_size` картинка 1 | 0.082s | 0.016s | 3.997s | **✗ 390958** | ~49x | ~246x |
| `lodepng_decode_hash` картинка 1 | 0.083s | 0.018s | 4.324s | **✗ -2029** | ~52x | ~241x |
| `lodepng_input_hash` картинка 1 | 0.082s | 0.006s | 1.917s | 9.715s | ~23x | ~333x |
| `lodepng_png_hash` картинка 1 | 0.089s | 0.016s | 3.978s | **✗ -295753527** | ~45x | ~251x |
| `chipmunk_hash_scene` 60 шагов | 0.054s | 0.009s | 2.875s | **✗ ERR** | ~53x | ~303x |
| `chipmunk_hash_scene` 600 шагов | 0.096s | 0.077s | 10.538s | **✗ ERR** | ~110x | ~136x |
| `chipmunk_variant` 600 шагов | 0.060s | 0.087s | 12.984s | **✗ ERR** | ~217x | ~149x |
| `chipmunk_probe_x` тело 0, 600 шагов | 0.057s | 0.070s | 10.748s | **✗ ERR** | ~188x | ~153x |
| `chipmunk_probe_y` тело 1, 600 шагов | 0.060s | 0.074s | 10.875s | **✗ ERR** | ~182x | ~146x |
| `chipmunk_probe_angle` тело 2, 600 шагов | 0.058s | 0.071s | 10.400s | **✗ ERR** | ~180x | ~146x |
| `secret_expected_length` | 0.034s | 0.003s | 1.857s | 9.700s | ~55x | ~591x |
| `secret_expected_crc32` | 0.036s | 0.003s | 1.884s | **✗ -1114115** | ~53x | ~591x |
| `profile_memory_walk` 400 итераций | 0.053s | 0.007s | 3.068s | 9.827s | ~57x | ~411x |
| `profile_math_shim` 400 итераций | 0.055s | 0.004s | 2.003s | 9.686s | ~37x | ~475x |
| `profile_branch_state` 400 итераций | 0.054s | 0.004s | 2.082s | 9.663s | ~38x | ~484x |
| `profile_space_freefall` 120 шагов | 0.055s | 0.006s | 2.240s | **✗ ERR** | ~41x | ~384x |
| `profile_space_collision` 120 шагов | 0.054s | 0.014s | 3.715s | **✗ ERR** | ~69x | ~273x |
| `profile_space_full` 120 шагов | 0.054s | 0.016s | 3.703s | **✗ ERR** | ~69x | ~233x |
| `h264mp4_decode_hash` 8 кадров | 0.125s | 0.025s | 3.720s | **✗ ERR** | ~30x | ~146x |
| `h264mp4_width` | 0.122s | 0.015s | 2.395s | **✗ ERR** | ~20x | ~163x |
| `h264mp4_height` | 0.128s | 0.015s | 2.371s | **✗ ERR** | ~19x | ~159x |
| `h264mp4_frame_count` 8 кадров | 0.123s | 0.025s | 3.689s | **✗ ERR** | ~30x | ~147x |
| `h264mp4_first_frame` | 0.121s | 0.015s | 2.344s | **✗ ERR** | ~19x | ~157x |
| `h264mp4_last_frame` 8 кадров | 0.119s | 0.025s | 3.705s | **✗ ERR** | ~31x | ~147x |
| `plmpeg_decode_hash` 8 кадров | 0.066s | 0.031s | 5.095s | **✗ -1** | ~77x | ~162x |
| `plmpeg_width` | 0.071s | 0.020s | 2.335s | **✗ -1** | ~33x | ~118x |
| `plmpeg_height` | 0.067s | 0.018s | 2.427s | **✗ -1** | ~36x | ~132x |
| `plmpeg_frame_count` 8 кадров | 0.075s | 0.032s | 5.022s | **✗ -1** | ~67x | ~159x |
| `plmpeg_first_frame` | 0.066s | 0.020s | 2.430s | **✗ -1** | ~37x | ~122x |
| `plmpeg_last_frame` 8 кадров | 0.069s | 0.030s | 5.177s | **✗ -1** | ~75x | ~173x |
| `plmpeg_stream_decode_hash` 8 кадров | 0.032s | 0.031s | 5.053s | **✗ -1** | ~156x | ~165x |
| `plmpeg_stream_width` | 0.031s | 0.020s | 2.369s | **✗ -1** | ~76x | ~119x |
| `plmpeg_stream_height` | 0.033s | 0.020s | 2.389s | **✗ -1** | ~73x | ~120x |
| `plmpeg_stream_frame_count` 8 кадров | 0.032s | 0.031s | 5.066s | **✗ -1** | ~158x | ~164x |
| `plmpeg_stream_first_frame` | 0.030s | 0.019s | 2.402s | **✗ -1** | ~80x | ~124x |
| `plmpeg_stream_last_frame` 8 кадров | 0.031s | 0.032s | 5.008s | **✗ -1** | ~163x | ~157x |
| `libjpeg_decode_hash` | 0.240s | 0.018s | 3.436s | **✗ ERR** | ~14x | ~196x |
| `libjpeg_width` | 0.240s | 0.017s | 3.123s | **✗ ERR** | ~13x | ~186x |
| `libjpeg_height` | 0.237s | 0.017s | 3.204s | **✗ ERR** | ~14x | ~190x |
| `libjpeg_components` | 0.239s | 0.017s | 3.205s | **✗ ERR** | ~13x | ~190x |
| `libjpeg_input_hash` | 0.238s | 0.010s | 1.901s | **✗ 62298897** | ~8.0x | ~185x |
| `libjpeg_rgb_size` | 0.236s | 0.017s | 3.224s | **✗ ERR** | ~14x | ~191x |
| `mjpeg_decode_hash` 12 кадров | 0.243s | 0.027s | 5.563s | **✗ -1** | ~23x | ~204x |
| `mjpeg_width` | 0.238s | 0.014s | 2.264s | **✗ -1** | ~9.5x | ~166x |
| `mjpeg_height` | 0.243s | 0.013s | 2.248s | **✗ -1** | ~9.2x | ~174x |
| `mjpeg_components` | 0.240s | 0.013s | 2.271s | **✗ -1** | ~9.5x | ~175x |
| `mjpeg_frame_count` 12 кадров | 0.239s | 0.027s | 5.501s | **✗ -1** | ~23x | ~201x |
| `mjpeg_first_frame` | 0.237s | 0.013s | 2.263s | **✗ -1** | ~9.6x | ~176x |
| `mjpeg_last_frame` 12 кадров | 0.250s | 0.027s | 5.611s | **✗ -1** | ~22x | ~205x |
| `mjpeg_input_hash` | 0.235s | 0.010s | 1.922s | **✗ -272398476** | ~8.2x | ~190x |
| `binjgb_decode_hash` 16 кадров | 0.090s | 0.154s | 32.226s | **✗ ERR** | ~358x | ~209x |
| `binjgb_width` | 0.078s | 0.018s | 1.921s | 9.746s | ~25x | ~104x |
| `binjgb_height` | 0.071s | 0.017s | 1.892s | 9.889s | ~26x | ~109x |
| `binjgb_frame_count` 16 кадров | 0.097s | 0.156s | 32.195s | **✗ ERR** | ~333x | ~206x |
| `binjgb_first_frame` | 0.074s | 0.028s | 3.793s | **✗ ERR** | ~51x | ~135x |
| `binjgb_last_frame` 16 кадров | 0.089s | 0.164s | 32.264s | **✗ ERR** | ~362x | ~196x |
| `builder_case_count` | 0.105s | 0.003s | 1.919s | 9.640s | ~18x | ~556x |
| `builder_c0_code_hash` вариант 0 | 0.109s | 0.007s | 2.021s | **✗ TIMEOUT** | ~19x | ~285x |
| `builder_c0_run_hash` вариант 0 | 0.116s | 0.007s | 2.030s | **✗ TIMEOUT** | ~17x | ~286x |
| `builder_c1_code_hash` вариант 1 | 0.122s | 0.006s | 2.128s | **✗ TIMEOUT** | ~17x | ~349x |
| `builder_c1_run_hash` вариант 1 | 0.107s | 0.006s | 2.011s | **✗ TIMEOUT** | ~19x | ~321x |
| `builder_c2_code_hash` вариант 2 | 0.104s | 0.008s | 2.056s | **✗ TIMEOUT** | ~20x | ~273x |
| `builder_c2_run_hash` вариант 2 | 0.116s | 0.007s | 2.058s | **✗ TIMEOUT** | ~18x | ~314x |

Совпало с baseline: wasmtime 86/86, wasm3 C 86/86, wasm3das 86/86, wasm3das(jit) 19/86. Расхождения:

- `tinyexpr_hash` 256 выражений — wasm3das(jit): -1001 вместо 141480662
- `tinyexpr_error_code` — wasm3das(jit): 1 вместо 6
- `miniz_roundtrip_hash` уровень 6 — wasm3das(jit): ERR вместо 58679047
- `miniz_probe_compressed_size` уровень 6 — wasm3das(jit): ERR вместо 2152
- `miniz_probe_crc32` — wasm3das(jit): -101385738 вместо 2035028898
- `miniz_full_hash` уровень 6 — wasm3das(jit): ERR вместо -2109846306
- `miniz_full_num_files` уровень 6 — wasm3das(jit): ERR вместо 3
- `miniz_full_archive_size` уровень 6 — wasm3das(jit): ERR вместо 3200
- `miniz_full_locate_mix` уровень 6 — wasm3das(jit): ERR вместо 258
- `miniz_full_extract_hash` уровень 6 — wasm3das(jit): ERR вместо 1129688585
- `miniz_full_validate` уровень 6 — wasm3das(jit): ERR вместо 1
- `miniz_file_hash` уровень 6 — wasm3das(jit): ERR вместо -138697996
- `miniz_file_num_files` уровень 6 — wasm3das(jit): ERR вместо 4
- `miniz_file_archive_size` уровень 6 — wasm3das(jit): ERR вместо 3473
- `miniz_file_extract_hash` уровень 6 — wasm3das(jit): ERR вместо 1747784103
- `miniz_file_in_place` уровень 6 — wasm3das(jit): ERR вместо 1
- `lodepng_roundtrip` картинка 0 — wasm3das(jit): -2029 вместо -1680879972
- `lodepng_encoded_size` картинка 0 — wasm3das(jit): 171240 вместо 3870
- `lodepng_decode_hash` картинка 0 — wasm3das(jit): -2029 вместо -2110661857
- `lodepng_png_hash` картинка 0 — wasm3das(jit): 221296935 вместо 79205344
- `lodepng_roundtrip` картинка 1 — wasm3das(jit): -2029 вместо -998874337
- `lodepng_encoded_size` картинка 1 — wasm3das(jit): 390958 вместо 6518
- `lodepng_decode_hash` картинка 1 — wasm3das(jit): -2029 вместо 496467531
- `lodepng_png_hash` картинка 1 — wasm3das(jit): -295753527 вместо -1526580224
- `chipmunk_hash_scene` 60 шагов — wasm3das(jit): ERR вместо -1855749543
- `chipmunk_hash_scene` 600 шагов — wasm3das(jit): ERR вместо 792478063
- `chipmunk_variant` 600 шагов — wasm3das(jit): ERR вместо -455480843
- `chipmunk_probe_x` тело 0, 600 шагов — wasm3das(jit): ERR вместо -1071644672
- `chipmunk_probe_y` тело 1, 600 шагов — wasm3das(jit): ERR вместо -216627709
- `chipmunk_probe_angle` тело 2, 600 шагов — wasm3das(jit): ERR вместо -343754584
- `secret_expected_crc32` — wasm3das(jit): -1114115 вместо -197449106
- `h264mp4_decode_hash` 8 кадров — wasm3das(jit): ERR вместо -419184337
- `h264mp4_width` — wasm3das(jit): ERR вместо 96
- `h264mp4_height` — wasm3das(jit): ERR вместо 64
- `h264mp4_frame_count` 8 кадров — wasm3das(jit): ERR вместо 8
- `h264mp4_first_frame` — wasm3das(jit): ERR вместо -53578803
- `h264mp4_last_frame` 8 кадров — wasm3das(jit): ERR вместо 131893473
- `plmpeg_decode_hash` 8 кадров — wasm3das(jit): -1 вместо -1675151828
- `plmpeg_width` — wasm3das(jit): -1 вместо 96
- `plmpeg_height` — wasm3das(jit): -1 вместо 64
- `plmpeg_frame_count` 8 кадров — wasm3das(jit): -1 вместо 8
- `plmpeg_first_frame` — wasm3das(jit): -1 вместо 1251253572
- `plmpeg_last_frame` 8 кадров — wasm3das(jit): -1 вместо 1609960924
- `plmpeg_stream_decode_hash` 8 кадров — wasm3das(jit): -1 вместо -1675151828
- `plmpeg_stream_width` — wasm3das(jit): -1 вместо 96
- `plmpeg_stream_height` — wasm3das(jit): -1 вместо 64
- `plmpeg_stream_frame_count` 8 кадров — wasm3das(jit): -1 вместо 8
- `plmpeg_stream_first_frame` — wasm3das(jit): -1 вместо 1251253572
- `plmpeg_stream_last_frame` 8 кадров — wasm3das(jit): -1 вместо 1609960924
- `libjpeg_decode_hash` — wasm3das(jit): ERR вместо 950757193
- `libjpeg_width` — wasm3das(jit): ERR вместо 227
- `libjpeg_height` — wasm3das(jit): ERR вместо 149
- `libjpeg_components` — wasm3das(jit): ERR вместо 3
- `libjpeg_input_hash` — wasm3das(jit): 62298897 вместо 1227945443
- `libjpeg_rgb_size` — wasm3das(jit): ERR вместо 101469
- `mjpeg_decode_hash` 12 кадров — wasm3das(jit): -1 вместо -598443464
- `mjpeg_width` — wasm3das(jit): -1 вместо 96
- `mjpeg_height` — wasm3das(jit): -1 вместо 64
- `mjpeg_components` — wasm3das(jit): -1 вместо 3
- `mjpeg_frame_count` 12 кадров — wasm3das(jit): -1 вместо 12
- `mjpeg_first_frame` — wasm3das(jit): -1 вместо -924446984
- `mjpeg_last_frame` 12 кадров — wasm3das(jit): -1 вместо 1556833302
- `mjpeg_input_hash` — wasm3das(jit): -272398476 вместо 755618084
- `binjgb_decode_hash` 16 кадров — wasm3das(jit): ERR вместо -1323964910
- `binjgb_frame_count` 16 кадров — wasm3das(jit): ERR вместо 16
- `binjgb_first_frame` — wasm3das(jit): ERR вместо 1015431621
- `binjgb_last_frame` 16 кадров — wasm3das(jit): ERR вместо 838717591

Ещё 12 строк(и) без документированного baseline остаются в таблице, их результат не проверяется.

## Итого

| runtime | суммарное время | × к wasm3 C |
| --- | ---: | ---: |
| wasmtime | 8.591s | ~4.3x |
| wasm3 C | 1.998s | ~1.0x |
| wasm3das | 6m47.4s | ~204x |
| wasm3das(jit) | 9m09.9s (43 ERR) | ~275x |

## Прогон

- Date (UTC): 2026-09-07T10:29:25Z
- Machine: Intel(R) Core(TM) i5-6200U CPU @ 2.30GHz (4 logical CPUs)
- Platform: Linux-6.12.107+deb13-amd64-x86_64-with-glibc2.41
- Checks: 98 x 4 runtimes
- Invocation: `tests/manual/run_fixtures.py`

Runtimes:

- wasmtime: `/home/andry/wasm3das/tools/bin/wasmtime` — wasmtime 48.0.1 (7bac2c277 2026-08-24)
- wasm3 C: `/home/andry/wasm3das/tools/bin/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Sep  6 2026 21:52:29, GCC 14.2.0
- wasm3das: `/home/andry/wasm3das/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(jit): `DASLANG=/home/andry/wasm3das/tmp/daslang-jit/bin/daslang WASM3DAS_JIT=1 /home/andry/wasm3das/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4

## Skipped entries

- `test_pure/render_frame 0.0` — runs ~400M float iterations; interpreter-in-interpreter would take hours
- `i64 probe_hash_i64_div_*_0/1` — debug probes, need i64 args, no documented baselines
- `host-adapter paths (gltf_rs, cgltf, wasm3, archive-secret extract, lodepng/plmpeg-stream host, lodepng_diag)` — need a Daslang memory-adapter driver, out of scope here
- `real-world-smollm2` — no wasm module built (upstream blocker on tensor callbacks)

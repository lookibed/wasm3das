# Spider manual fixtures: parity and timing

## Основные

По одной продакшен-конфигурации на модуль: самый тяжёлый реальный экспорт (декодер, полный цикл, длинная симуляция). Остальные экспорты и вариации аргументов — справочной таблицей ниже.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `add` 1 2 | 0.012s | 0.001s | 0.180s | 0.666s | 0.030s | 0.864s | ~15x | ~133x |
| `hash_loop` seed 123456789, 200000 итераций | 0.014s | 0.004s | 0.484s | 0.828s | 0.045s | 0.909s | ~34x | ~116x |
| `hash_f32` 2048 элементов | 0.014s | 0.001s | 0.183s | 0.654s | 0.031s | 0.888s | ~13x | ~133x |
| `hash_f64` 2048 элементов | 0.012s | 0.002s | 0.191s | 0.672s | 0.029s | 0.871s | ~16x | ~108x |
| `hash_i64_mix` 512 элементов | 0.014s | 0.001s | 0.187s | 0.684s | 0.032s | 0.918s | ~14x | ~127x |
| `hash_i64_div` 512 элементов | 0.013s | 0.002s | 0.189s | 0.724s | 0.031s | 0.902s | ~14x | ~109x |
| `tinyexpr_hash` 256 выражений | 0.019s | 0.003s | 0.254s | 0.724s | 0.034s | 0.896s | ~13x | ~92x |
| `miniz_roundtrip_hash` уровень 6 | 0.028s | 0.005s | 0.406s | 0.857s | 0.043s | 0.900s | ~15x | ~77x |
| `miniz_full_hash` уровень 6 | 0.031s | 0.012s | 0.481s | 0.772s | 0.045s | 0.907s | ~15x | ~41x |
| `miniz_file_hash` уровень 6 | 0.033s | 0.022s | 0.576s | 0.929s | 0.053s | 0.955s | ~17x | ~26x |
| `lodepng_roundtrip` картинка 1 | 0.038s | 0.028s | 1.181s | 1.304s | 0.080s | 1.054s | ~31x | ~42x |
| `chipmunk_hash_scene` 600 шагов | 0.029s | 0.072s | 3.641s | 2.899s | 0.208s | 1.408s | ~126x | ~51x |
| `secret_expected_crc32` | 0.028s | 0.003s | 0.202s | 0.895s | 0.033s | 1.095s | ~7.1x | ~66x |
| `profile_memory_walk` 400 итераций | 0.029s | 0.008s | 0.683s | 1.247s | 0.063s | 1.199s | ~23x | ~81x |
| `profile_math_shim` 400 итераций | 0.029s | 0.006s | 0.263s | 1.068s | 0.039s | 1.022s | ~9.1x | ~45x |
| `profile_branch_state` 400 итераций | 0.028s | 0.006s | 0.270s | 1.057s | 0.037s | 1.128s | ~9.7x | ~45x |
| `profile_space_freefall` 120 шагов | 0.028s | 0.007s | 0.361s | 1.164s | 0.046s | 1.022s | ~13x | ~51x |
| `profile_space_collision` 120 шагов | 0.026s | 0.017s | 0.961s | 1.277s | 0.071s | 1.083s | ~37x | ~57x |
| `profile_space_full` 120 шагов | 0.027s | 0.017s | 0.916s | 1.274s | 0.077s | 1.113s | ~34x | ~54x |
| `h264mp4_decode_hash` 8 кадров | 0.051s | 0.044s | 0.991s | 1.350s | 0.084s | 1.124s | ~19x | ~23x |
| `plmpeg_decode_hash` 8 кадров | 0.034s | 0.068s | 1.486s | 1.719s | 0.099s | 1.200s | ~44x | ~22x |
| `plmpeg_stream_decode_hash` 8 кадров | 0.023s | 0.071s | 1.453s | 1.639s | 0.105s | 1.187s | ~64x | ~20x |
| `libjpeg_decode_hash` | 0.063s | 0.035s | 0.798s | 0.997s | 0.065s | 0.969s | ~13x | ~23x |
| `mjpeg_decode_hash` 12 кадров | 0.065s | 0.051s | 1.624s | 1.556s | 0.107s | 1.093s | ~25x | ~32x |
| `binjgb_decode_hash` 16 кадров | 0.053s | 0.203s | 11.645s | 8.158s | 0.587s | 2.520s | ~219x | ~57x |
| `builder_c0_run_hash` вариант 0 | 0.048s | 0.007s | 0.273s | 0.653s | 0.041s | 0.869s | ~5.7x | ~40x |

| runtime | суммарное время (основные) | × к wasm3 C | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: |
| wasmtime | 0.790s | ~1.1x | 0.481s | ~0.7x |
| wasm3 C | 0.698s | ~1.0x | 0.663s | ~1.0x |
| wasm3das(inter) | 29.880s | ~43x | 25.198s | ~38x |
| wasm3das(aot) | 35.769s | ~51x | 18.768s | ~28x |
| wasm3das(aot_ctx) | 2.115s | ~3.0x | 1.351s | ~2.0x |
| wasm3das(jit) | 28.097s | ~40x | 5.627s | ~8.5x |

## Вариации аргументов и остальные экспорты

Справочные строки: остальные экспорты модулей, отладочные пробы и остальные конфигурации аргументов. Методика и колонки те же.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hash_loop` seed 1, 65536 итераций | 0.012s | 0.002s | 0.272s | 0.779s | 0.035s | 0.909s | ~24x | ~116x |
| `probe_div_s64` | 0.014s | 0.002s | 0.184s | 0.753s | 0.031s | 0.933s | ~13x | ~121x |
| `probe_rem_s64` | 0.014s | 0.002s | 0.191s | 0.722s | 0.031s | 0.920s | ~14x | ~121x |
| `probe_div_u64` | 0.013s | 0.001s | 0.185s | 0.737s | 0.030s | 0.881s | ~14x | ~141x |
| `probe_rem_u64` | 0.013s | 0.002s | 0.181s | 0.677s | 0.030s | 0.874s | ~13x | ~108x |
| `tinyexpr_error_code` | 0.017s | 0.002s | 0.192s | 0.697s | 0.031s | 0.911s | ~11x | ~117x |
| `miniz_probe_compressed_size` уровень 6 | 0.027s | 0.005s | 0.341s | 0.772s | 0.040s | 0.914s | ~13x | ~70x |
| `miniz_probe_crc32` | 0.027s | 0.003s | 0.206s | 0.675s | 0.032s | 0.888s | ~7.8x | ~81x |
| `miniz_probe_adler32` | 0.027s | 0.002s | 0.205s | 0.665s | 0.032s | 0.880s | ~7.5x | ~83x |
| `miniz_probe_fold_hash` | 0.026s | 0.002s | 0.201s | 0.683s | 0.033s | 0.885s | ~7.7x | ~85x |
| `miniz_full_num_files` уровень 6 | 0.031s | 0.011s | 0.474s | 0.826s | 0.046s | 0.920s | ~15x | ~42x |
| `miniz_full_archive_size` уровень 6 | 0.031s | 0.011s | 0.489s | 0.886s | 0.046s | 0.928s | ~16x | ~43x |
| `miniz_full_locate_mix` уровень 6 | 0.032s | 0.012s | 0.502s | 1.034s | 0.049s | 0.980s | ~16x | ~43x |
| `miniz_full_extract_hash` уровень 6 | 0.035s | 0.012s | 0.506s | 0.900s | 0.048s | 0.974s | ~15x | ~43x |
| `miniz_full_validate` уровень 6 | 0.034s | 0.012s | 0.502s | 0.900s | 0.047s | 0.952s | ~15x | ~41x |
| `miniz_file_num_files` уровень 6 | 0.034s | 0.021s | 0.574s | 0.867s | 0.053s | 0.936s | ~17x | ~27x |
| `miniz_file_archive_size` уровень 6 | 0.032s | 0.022s | 0.572s | 0.900s | 0.053s | 0.940s | ~18x | ~26x |
| `miniz_file_extract_hash` уровень 6 | 0.034s | 0.022s | 0.570s | 0.863s | 0.052s | 0.947s | ~17x | ~26x |
| `miniz_file_in_place` уровень 6 | 0.033s | 0.021s | 0.568s | 0.901s | 0.054s | 0.946s | ~17x | ~27x |
| `lodepng_roundtrip` картинка 0 | 0.037s | 0.023s | 0.836s | 1.054s | 0.066s | 0.970s | ~23x | ~37x |
| `lodepng_encoded_size` картинка 0 | 0.036s | 0.021s | 0.742s | 1.002s | 0.061s | 0.966s | ~21x | ~35x |
| `lodepng_decode_hash` картинка 0 | 0.037s | 0.023s | 0.847s | 1.109s | 0.065s | 0.975s | ~23x | ~38x |
| `lodepng_input_hash` картинка 0 | 0.034s | 0.013s | 0.194s | 0.753s | 0.032s | 0.885s | ~5.7x | ~15x |
| `lodepng_png_hash` картинка 0 | 0.035s | 0.021s | 0.742s | 1.017s | 0.061s | 1.013s | ~21x | ~35x |
| `lodepng_encoded_size` картинка 1 | 0.037s | 0.026s | 1.023s | 1.741s | 0.076s | 1.092s | ~28x | ~40x |
| `lodepng_decode_hash` картинка 1 | 0.041s | 0.030s | 1.217s | 1.316s | 0.079s | 1.017s | ~30x | ~40x |
| `lodepng_input_hash` картинка 1 | 0.036s | 0.013s | 0.199s | 0.696s | 0.034s | 0.923s | ~5.5x | ~15x |
| `lodepng_png_hash` картинка 1 | 0.037s | 0.024s | 1.033s | 1.367s | 0.072s | 1.032s | ~28x | ~43x |
| `chipmunk_hash_scene` 60 шагов | 0.025s | 0.011s | 0.557s | 1.000s | 0.052s | 0.962s | ~22x | ~52x |
| `chipmunk_variant` 600 шагов | 0.029s | 0.089s | 4.582s | 3.619s | 0.266s | 1.587s | ~159x | ~51x |
| `chipmunk_probe_x` тело 0, 600 шагов | 0.027s | 0.070s | 3.602s | 2.951s | 0.209s | 1.394s | ~133x | ~51x |
| `chipmunk_probe_y` тело 1, 600 шагов | 0.027s | 0.070s | 3.604s | 2.905s | 0.211s | 1.409s | ~132x | ~52x |
| `chipmunk_probe_angle` тело 2, 600 шагов | 0.027s | 0.071s | 3.696s | 3.020s | 0.217s | 1.501s | ~135x | ~52x |
| `secret_expected_length` | 0.029s | 0.003s | 0.193s | 0.882s | 0.033s | 1.014s | ~6.7x | ~69x |
| `h264mp4_width` | 0.048s | 0.031s | 0.444s | 0.930s | 0.052s | 0.986s | ~9.2x | ~14x |
| `h264mp4_height` | 0.048s | 0.030s | 0.438s | 0.938s | 0.051s | 0.993s | ~9.2x | ~14x |
| `h264mp4_frame_count` 8 кадров | 0.050s | 0.042s | 0.967s | 1.396s | 0.087s | 1.204s | ~20x | ~23x |
| `h264mp4_first_frame` | 0.050s | 0.031s | 0.448s | 0.959s | 0.052s | 1.015s | ~9.0x | ~14x |
| `h264mp4_last_frame` 8 кадров | 0.051s | 0.043s | 0.997s | 1.273s | 0.082s | 1.066s | ~20x | ~23x |
| `plmpeg_width` | 0.031s | 0.053s | 0.415s | 1.029s | 0.058s | 1.013s | ~13x | ~7.9x |
| `plmpeg_height` | 0.032s | 0.053s | 0.418s | 1.008s | 0.051s | 0.973s | ~13x | ~7.9x |
| `plmpeg_frame_count` 8 кадров | 0.033s | 0.068s | 1.433s | 1.727s | 0.117s | 1.176s | ~44x | ~21x |
| `plmpeg_first_frame` | 0.033s | 0.051s | 0.407s | 1.007s | 0.059s | 1.004s | ~12x | ~7.9x |
| `plmpeg_last_frame` 8 кадров | 0.033s | 0.069s | 1.416s | 1.657s | 0.100s | 1.148s | ~43x | ~20x |
| `plmpeg_stream_width` | 0.023s | 0.053s | 0.422s | 1.040s | 0.053s | 1.035s | ~19x | ~7.9x |
| `plmpeg_stream_height` | 0.023s | 0.053s | 0.422s | 0.971s | 0.049s | 0.966s | ~19x | ~8.0x |
| `plmpeg_stream_frame_count` 8 кадров | 0.024s | 0.068s | 1.409s | 1.599s | 0.100s | 1.163s | ~60x | ~21x |
| `plmpeg_stream_first_frame` | 0.023s | 0.053s | 0.416s | 0.974s | 0.052s | 1.003s | ~18x | ~7.9x |
| `plmpeg_stream_last_frame` 8 кадров | 0.024s | 0.069s | 1.378s | 1.499s | 0.093s | 1.049s | ~58x | ~20x |
| `libjpeg_width` | 0.060s | 0.035s | 0.699s | 0.986s | 0.060s | 0.956s | ~12x | ~20x |
| `libjpeg_height` | 0.059s | 0.034s | 0.683s | 0.969s | 0.061s | 0.946s | ~12x | ~20x |
| `libjpeg_components` | 0.061s | 0.034s | 0.691s | 0.986s | 0.061s | 0.941s | ~11x | ~20x |
| `libjpeg_input_hash` | 0.060s | 0.026s | 0.192s | 0.673s | 0.035s | 0.879s | ~3.2x | ~7.5x |
| `libjpeg_rgb_size` | 0.062s | 0.034s | 0.693s | 0.955s | 0.060s | 0.971s | ~11x | ~20x |
| `mjpeg_width` | 0.061s | 0.028s | 0.355s | 0.748s | 0.046s | 0.909s | ~5.9x | ~13x |
| `mjpeg_height` | 0.061s | 0.028s | 0.353s | 0.750s | 0.045s | 0.906s | ~5.8x | ~13x |
| `mjpeg_components` | 0.062s | 0.028s | 0.353s | 0.776s | 0.047s | 0.912s | ~5.7x | ~13x |
| `mjpeg_frame_count` 12 кадров | 0.061s | 0.049s | 1.572s | 1.535s | 0.103s | 1.074s | ~26x | ~32x |
| `mjpeg_first_frame` | 0.059s | 0.028s | 0.346s | 0.731s | 0.044s | 0.892s | ~5.9x | ~12x |
| `mjpeg_last_frame` 12 кадров | 0.060s | 0.049s | 1.602s | 1.552s | 0.101s | 1.074s | ~27x | ~33x |
| `mjpeg_input_hash` | 0.059s | 0.025s | 0.204s | 0.679s | 0.037s | 0.870s | ~3.5x | ~8.1x |
| `binjgb_width` | 0.044s | 0.047s | 0.188s | 0.662s | 0.038s | 0.868s | ~4.3x | ~4.0x |
| `binjgb_height` | 0.041s | 0.047s | 0.196s | 0.650s | 0.039s | 0.866s | ~4.7x | ~4.2x |
| `binjgb_frame_count` 16 кадров | 0.052s | 0.203s | 11.724s | 7.992s | 0.555s | 2.503s | ~224x | ~58x |
| `binjgb_first_frame` | 0.044s | 0.057s | 0.950s | 1.124s | 0.075s | 0.966s | ~22x | ~17x |
| `binjgb_last_frame` 16 кадров | 0.053s | 0.202s | 11.983s | 8.158s | 0.554s | 2.454s | ~227x | ~59x |
| `builder_case_count` | 0.048s | 0.005s | 0.182s | 0.667s | 0.032s | 0.867s | ~3.8x | ~36x |
| `builder_c0_code_hash` вариант 0 | 0.048s | 0.007s | 0.274s | 0.648s | 0.040s | 0.872s | ~5.8x | ~42x |
| `builder_c1_code_hash` вариант 1 | 0.047s | 0.007s | 0.282s | 0.623s | 0.042s | 0.872s | ~6.0x | ~41x |
| `builder_c1_run_hash` вариант 1 | 0.050s | 0.007s | 0.288s | 0.668s | 0.042s | 0.870s | ~5.8x | ~42x |
| `builder_c2_code_hash` вариант 2 | 0.048s | 0.007s | 0.290s | 0.631s | 0.043s | 0.898s | ~6.0x | ~40x |
| `builder_c2_run_hash` вариант 2 | 0.049s | 0.007s | 0.304s | 0.682s | 0.045s | 0.899s | ~6.2x | ~42x |

Все результаты совпали с baseline (wasmtime 86/86, wasm3 C 86/86, wasm3das(inter) 86/86, wasm3das(aot) 86/86, wasm3das(aot_ctx) 86/86, wasm3das(jit) 86/86)

Ещё 12 строк(и) без документированного baseline остаются в таблице, их результат не проверяется.

## Итого (весь набор: основные + вариации)

| runtime | суммарное время | × к wasm3 C | старт (`fixtures/add`) | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasmtime | 3.543s | ~1.1x | 0.012s | 2.378s | ~0.8x |
| wasm3 C | 3.136s | ~1.0x | 0.001s | 3.002s | ~1.0x |
| wasm3das(inter) | 1m45.7s | ~34x | 0.180s | 1m28.0s | ~29x |
| wasm3das(aot) | 2m07.3s | ~41x | 0.654s | 1m03.2s | ~21x |
| wasm3das(aot_ctx) | 7.683s | ~2.5x | 0.029s | 4.804s | ~1.6x |
| wasm3das(jit) | 1m42.4s | ~33x | 0.864s | 17.718s | ~5.9x |

Старт это минимальное полное время среди строк без исполнения (`add`, `hash_f32`, `hash_f64`), «без старта» это сумма минус старт на каждую засчитанную строку: оценка рядом с честным полным временем, не вместо него.

## Прогон

- Date (UTC): 2026-09-10T09:03:26Z
- Machine: AMD Ryzen 7 7435HS (16 logical CPUs)
- Platform: Linux-6.6.87.2-microsoft-standard-WSL2-x86_64-with-glibc2.35
- Checks: 98 x 6 runtimes
- Invocation: `tests/manual/run_fixtures.py --runtimes wasmtime,wasm3,das,native,aot_ctx,jit`

Runtimes:

- wasmtime: `/root/wasm3das/tools/bin/wasmtime` — wasmtime 48.0.1 (7bac2c277 2026-08-24)
- wasm3 C: `/root/wasm3das/tools/bin/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Sep  9 2026 18:03:13, GCC 11.4.0
- wasm3das(inter): `/root/wasm3das/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(aot): `/root/wasm3das/tmp/native/bin/wasm3das` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(aot_ctx): `/root/wasm3das/tmp/native-ctx/bin/wasm3das` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(jit): `DASLANG=/root/daScript/bin/daslang WASM3DAS_JIT=1 WASM3DAS_JIT_OPTS=--jit-opt-level=0 /root/wasm3das/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4

## Skipped entries

- `test_pure/render_frame 0.0` — runs ~400M float iterations; interpreter-in-interpreter would take hours
- `i64 probe_hash_i64_div_*_0/1` — debug probes, need i64 args, no documented baselines
- `host-adapter paths (gltf_rs, cgltf, wasm3, archive-secret extract, lodepng/plmpeg-stream host, lodepng_diag)` — need a Daslang memory-adapter driver, out of scope here
- `real-world-smollm2` — no wasm module built (upstream blocker on tensor callbacks)

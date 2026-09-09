# Spider manual fixtures: parity and timing

## Основные

По одной продакшен-конфигурации на модуль: самый тяжёлый реальный экспорт (декодер, полный цикл, длинная симуляция). Остальные экспорты и вариации аргументов — справочной таблицей ниже.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `add` 1 2 | 0.078s | 0.001s | 1.048s | 0.894s | 0.032s | ~13x | ~707x |
| `hash_loop` seed 123456789, 200000 итераций | 0.015s | 0.004s | 0.582s | 0.991s | 0.050s | ~38x | ~131x |
| `hash_f32` 2048 элементов | 0.015s | 0.002s | 0.215s | 0.883s | 0.032s | ~14x | ~142x |
| `hash_f64` 2048 элементов | 0.012s | 0.001s | 0.220s | 0.874s | 0.033s | ~19x | ~151x |
| `hash_i64_mix` 512 элементов | 0.015s | 0.002s | 0.211s | 0.896s | 0.032s | ~15x | ~135x |
| `hash_i64_div` 512 элементов | 0.014s | 0.002s | 0.215s | 0.823s | 0.032s | ~16x | ~130x |
| `tinyexpr_hash` 256 выражений | 0.018s | 0.003s | 0.291s | 0.977s | 0.036s | ~16x | ~98x |
| `miniz_roundtrip_hash` уровень 6 | 0.030s | 0.005s | 0.460s | 0.878s | 0.045s | ~15x | ~88x |
| `miniz_full_hash` уровень 6 | 0.035s | 0.013s | 0.548s | 1.024s | 0.057s | ~16x | ~43x |
| `miniz_file_hash` уровень 6 | 0.036s | 0.024s | 0.650s | 1.099s | 0.070s | ~18x | ~28x |
| `lodepng_roundtrip` картинка 1 | 0.039s | 0.030s | 1.308s | 1.455s | 0.096s | ~34x | ~43x |
| `chipmunk_hash_scene` 600 шагов | 0.029s | 0.076s | 4.125s | 3.330s | 0.232s | ~143x | ~54x |
| `secret_expected_crc32` | 0.028s | 0.003s | 0.214s | 0.880s | 0.034s | ~7.6x | ~67x |
| `profile_memory_walk` 400 итераций | 0.026s | 0.008s | 0.678s | 1.139s | 0.058s | ~26x | ~83x |
| `profile_math_shim` 400 итераций | 0.026s | 0.005s | 0.260s | 0.875s | 0.038s | ~9.9x | ~51x |
| `profile_branch_state` 400 итераций | 0.030s | 0.005s | 0.284s | 0.883s | 0.039s | ~9.5x | ~54x |
| `profile_space_freefall` 120 шагов | 0.025s | 0.007s | 0.370s | 1.034s | 0.044s | ~15x | ~51x |
| `profile_space_collision` 120 шагов | 0.027s | 0.017s | 1.026s | 1.370s | 0.077s | ~38x | ~61x |
| `profile_space_full` 120 шагов | 0.027s | 0.018s | 1.027s | 1.451s | 0.079s | ~38x | ~58x |
| `h264mp4_decode_hash` 8 кадров | 0.048s | 0.045s | 1.079s | 1.481s | 0.103s | ~22x | ~24x |
| `plmpeg_decode_hash` 8 кадров | 0.032s | 0.072s | 1.569s | 1.606s | 0.140s | ~50x | ~22x |
| `plmpeg_stream_decode_hash` 8 кадров | 0.024s | 0.072s | 1.594s | 1.642s | 0.143s | ~68x | ~22x |
| `libjpeg_decode_hash` | 0.071s | 0.039s | 0.905s | 1.330s | 0.090s | ~13x | ~23x |
| `mjpeg_decode_hash` 12 кадров | 0.067s | 0.052s | 1.824s | 1.758s | 0.132s | ~27x | ~35x |
| `binjgb_decode_hash` 16 кадров | 0.059s | 0.220s | 13.305s | 9.517s | 0.656s | ~224x | ~60x |
| `builder_c0_run_hash` вариант 0 | 0.053s | 0.008s | 0.331s | 0.996s | 0.048s | ~6.2x | ~44x |

| runtime | суммарное время (основные) | × к wasm3 C | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: |
| wasmtime | 0.877s | ~1.2x | 0.569s | ~0.8x |
| wasm3 C | 0.735s | ~1.0x | 0.697s | ~1.0x |
| wasm3das(inter) | 34.338s | ~47x | 28.744s | ~41x |
| wasm3das(aot) | 40.086s | ~55x | 17.369s | ~25x |
| wasm3das(aot_ctx) | 2.431s | ~3.3x | 1.588s | ~2.3x |

## Вариации аргументов и остальные экспорты

Справочные строки: остальные экспорты модулей, отладочные пробы и остальные конфигурации аргументов. Методика и колонки те же.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hash_loop` seed 1, 65536 итераций | 0.012s | 0.003s | 0.332s | 0.870s | 0.037s | ~27x | ~130x |
| `probe_div_s64` | 0.013s | 0.001s | 0.211s | 0.912s | 0.032s | ~16x | ~149x |
| `probe_rem_s64` | 0.014s | 0.002s | 0.212s | 0.853s | 0.032s | ~15x | ~136x |
| `probe_div_u64` | 0.013s | 0.001s | 0.209s | 0.797s | 0.032s | ~16x | ~147x |
| `probe_rem_u64` | 0.013s | 0.001s | 0.209s | 0.913s | 0.032s | ~16x | ~143x |
| `tinyexpr_error_code` | 0.018s | 0.002s | 0.216s | 0.779s | 0.034s | ~12x | ~119x |
| `miniz_probe_compressed_size` уровень 6 | 0.028s | 0.004s | 0.385s | 0.900s | 0.042s | ~14x | ~88x |
| `miniz_probe_crc32` | 0.030s | 0.002s | 0.233s | 0.868s | 0.035s | ~7.8x | ~96x |
| `miniz_probe_adler32` | 0.028s | 0.002s | 0.235s | 0.800s | 0.034s | ~8.3x | ~97x |
| `miniz_probe_fold_hash` | 0.030s | 0.003s | 0.236s | 0.812s | 0.034s | ~7.7x | ~86x |
| `miniz_full_num_files` уровень 6 | 0.034s | 0.013s | 0.562s | 0.950s | 0.056s | ~16x | ~44x |
| `miniz_full_archive_size` уровень 6 | 0.034s | 0.013s | 0.562s | 0.992s | 0.057s | ~17x | ~43x |
| `miniz_full_locate_mix` уровень 6 | 0.034s | 0.013s | 0.554s | 1.051s | 0.056s | ~16x | ~43x |
| `miniz_full_extract_hash` уровень 6 | 0.033s | 0.013s | 0.567s | 1.033s | 0.058s | ~17x | ~43x |
| `miniz_full_validate` уровень 6 | 0.033s | 0.012s | 0.546s | 0.945s | 0.056s | ~16x | ~44x |
| `miniz_file_num_files` уровень 6 | 0.037s | 0.025s | 0.656s | 1.135s | 0.069s | ~18x | ~26x |
| `miniz_file_archive_size` уровень 6 | 0.033s | 0.024s | 0.653s | 1.130s | 0.070s | ~20x | ~27x |
| `miniz_file_extract_hash` уровень 6 | 0.035s | 0.024s | 0.649s | 1.118s | 0.071s | ~18x | ~28x |
| `miniz_file_in_place` уровень 6 | 0.035s | 0.023s | 0.655s | 1.105s | 0.070s | ~18x | ~28x |
| `lodepng_roundtrip` картинка 0 | 0.039s | 0.025s | 0.981s | 1.247s | 0.082s | ~25x | ~40x |
| `lodepng_encoded_size` картинка 0 | 0.039s | 0.023s | 0.862s | 1.181s | 0.075s | ~22x | ~37x |
| `lodepng_decode_hash` картинка 0 | 0.039s | 0.025s | 0.958s | 1.376s | 0.081s | ~25x | ~38x |
| `lodepng_input_hash` картинка 0 | 0.039s | 0.015s | 0.233s | 0.924s | 0.045s | ~6.0x | ~16x |
| `lodepng_png_hash` картинка 0 | 0.038s | 0.023s | 0.861s | 1.296s | 0.074s | ~22x | ~37x |
| `lodepng_encoded_size` картинка 1 | 0.039s | 0.028s | 1.161s | 1.515s | 0.089s | ~29x | ~41x |
| `lodepng_decode_hash` картинка 1 | 0.041s | 0.030s | 1.314s | 1.568s | 0.097s | ~32x | ~43x |
| `lodepng_input_hash` картинка 1 | 0.040s | 0.015s | 0.245s | 0.965s | 0.046s | ~6.2x | ~17x |
| `lodepng_png_hash` картинка 1 | 0.039s | 0.027s | 1.148s | 1.452s | 0.090s | ~29x | ~42x |
| `chipmunk_hash_scene` 60 шагов | 0.026s | 0.011s | 0.646s | 1.211s | 0.059s | ~25x | ~59x |
| `chipmunk_variant` 600 шагов | 0.032s | 0.097s | 5.063s | 4.077s | 0.289s | ~161x | ~52x |
| `chipmunk_probe_x` тело 0, 600 шагов | 0.028s | 0.077s | 4.119s | 3.480s | 0.240s | ~145x | ~53x |
| `chipmunk_probe_y` тело 1, 600 шагов | 0.030s | 0.078s | 4.127s | 3.425s | 0.236s | ~136x | ~53x |
| `chipmunk_probe_angle` тело 2, 600 шагов | 0.029s | 0.074s | 4.080s | 3.399s | 0.236s | ~141x | ~55x |
| `secret_expected_length` | 0.027s | 0.003s | 0.213s | 0.937s | 0.035s | ~7.9x | ~73x |
| `h264mp4_width` | 0.044s | 0.031s | 0.469s | 0.914s | 0.073s | ~11x | ~15x |
| `h264mp4_height` | 0.047s | 0.032s | 0.474s | 0.963s | 0.073s | ~10x | ~15x |
| `h264mp4_frame_count` 8 кадров | 0.044s | 0.044s | 1.045s | 1.323s | 0.103s | ~24x | ~24x |
| `h264mp4_first_frame` | 0.045s | 0.032s | 0.475s | 0.954s | 0.074s | ~10x | ~15x |
| `h264mp4_last_frame` 8 кадров | 0.043s | 0.045s | 1.046s | 1.355s | 0.104s | ~24x | ~23x |
| `plmpeg_width` | 0.032s | 0.053s | 0.481s | 0.947s | 0.091s | ~15x | ~9.0x |
| `plmpeg_height` | 0.031s | 0.054s | 0.481s | 0.956s | 0.091s | ~15x | ~9.0x |
| `plmpeg_frame_count` 8 кадров | 0.034s | 0.072s | 1.577s | 1.639s | 0.140s | ~47x | ~22x |
| `plmpeg_first_frame` | 0.031s | 0.054s | 0.471s | 1.106s | 0.090s | ~15x | ~8.8x |
| `plmpeg_last_frame` 8 кадров | 0.032s | 0.072s | 1.581s | 1.639s | 0.139s | ~50x | ~22x |
| `plmpeg_stream_width` | 0.024s | 0.055s | 0.483s | 1.062s | 0.092s | ~20x | ~8.8x |
| `plmpeg_stream_height` | 0.023s | 0.055s | 0.485s | 0.979s | 0.094s | ~21x | ~8.8x |
| `plmpeg_stream_frame_count` 8 кадров | 0.022s | 0.073s | 1.649s | 1.742s | 0.142s | ~75x | ~23x |
| `plmpeg_stream_first_frame` | 0.022s | 0.054s | 0.481s | 1.072s | 0.092s | ~22x | ~8.8x |
| `plmpeg_stream_last_frame` 8 кадров | 0.024s | 0.072s | 1.583s | 1.757s | 0.140s | ~67x | ~22x |
| `libjpeg_width` | 0.064s | 0.037s | 0.817s | 1.212s | 0.086s | ~13x | ~22x |
| `libjpeg_height` | 0.064s | 0.038s | 0.813s | 1.255s | 0.086s | ~13x | ~22x |
| `libjpeg_components` | 0.065s | 0.036s | 0.799s | 1.181s | 0.085s | ~12x | ~22x |
| `libjpeg_input_hash` | 0.065s | 0.027s | 0.237s | 0.860s | 0.057s | ~3.6x | ~8.8x |
| `libjpeg_rgb_size` | 0.072s | 0.036s | 0.797s | 1.186s | 0.086s | ~11x | ~22x |
| `mjpeg_width` | 0.070s | 0.031s | 0.423s | 0.920s | 0.070s | ~6.1x | ~14x |
| `mjpeg_height` | 0.065s | 0.031s | 0.428s | 0.992s | 0.069s | ~6.6x | ~14x |
| `mjpeg_components` | 0.068s | 0.031s | 0.426s | 0.984s | 0.069s | ~6.3x | ~14x |
| `mjpeg_frame_count` 12 кадров | 0.070s | 0.054s | 1.860s | 1.830s | 0.134s | ~27x | ~34x |
| `mjpeg_first_frame` | 0.066s | 0.031s | 0.429s | 1.000s | 0.069s | ~6.5x | ~14x |
| `mjpeg_last_frame` 12 кадров | 0.066s | 0.054s | 1.842s | 1.849s | 0.130s | ~28x | ~34x |
| `mjpeg_input_hash` | 0.065s | 0.028s | 0.255s | 0.834s | 0.058s | ~3.9x | ~9.2x |
| `binjgb_width` | 0.044s | 0.050s | 0.261s | 0.937s | 0.081s | ~5.9x | ~5.2x |
| `binjgb_height` | 0.045s | 0.051s | 0.262s | 0.983s | 0.079s | ~5.8x | ~5.1x |
| `binjgb_frame_count` 16 кадров | 0.056s | 0.221s | 13.331s | 9.196s | 0.652s | ~236x | ~60x |
| `binjgb_first_frame` | 0.046s | 0.061s | 1.099s | 1.422s | 0.124s | ~24x | ~18x |
| `binjgb_last_frame` 16 кадров | 0.059s | 0.226s | 14.360s | 9.324s | 0.652s | ~243x | ~64x |
| `builder_case_count` | 0.056s | 0.005s | 0.220s | 0.850s | 0.038s | ~3.9x | ~41x |
| `builder_c0_code_hash` вариант 0 | 0.057s | 0.007s | 0.324s | 0.956s | 0.047s | ~5.7x | ~44x |
| `builder_c1_code_hash` вариант 1 | 0.056s | 0.008s | 0.337s | 0.861s | 0.049s | ~6.0x | ~44x |
| `builder_c1_run_hash` вариант 1 | 0.054s | 0.008s | 0.341s | 0.958s | 0.050s | ~6.3x | ~44x |
| `builder_c2_code_hash` вариант 2 | 0.059s | 0.008s | 0.347s | 0.992s | 0.050s | ~5.9x | ~43x |
| `builder_c2_run_hash` вариант 2 | 0.053s | 0.008s | 0.348s | 0.928s | 0.049s | ~6.5x | ~45x |

Все результаты совпали с baseline (wasmtime 86/86, wasm3 C 86/86, wasm3das(inter) 86/86, wasm3das(aot) 86/86, wasm3das(aot_ctx) 86/86)

Ещё 12 строк(и) без документированного baseline остаются в таблице, их результат не проверяется.

## Итого (весь набор: основные + вариации)

| runtime | суммарное время | × к wasm3 C | старт (`fixtures/add`) | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasmtime | 3.797s | ~1.1x | 0.012s | 2.638s | ~0.8x |
| wasm3 C | 3.354s | ~1.0x | 0.001s | 3.212s | ~1.0x |
| wasm3das(inter) | 2m01.4s | ~36x | 0.215s | 1m40.3s | ~31x |
| wasm3das(aot) | 2m26.0s | ~44x | 0.874s | 1m00.4s | ~19x |
| wasm3das(aot_ctx) | 9.518s | ~2.8x | 0.032s | 6.342s | ~2.0x |

Старт это минимальное полное время среди строк без исполнения (`add`, `hash_f32`, `hash_f64`), «без старта» это сумма минус старт на каждую засчитанную строку: оценка рядом с честным полным временем, не вместо него.

## Прогон

- Date (UTC): 2026-09-09T15:07:38Z
- Machine: AMD Ryzen 7 7435HS (16 logical CPUs)
- Platform: Linux-6.6.87.2-microsoft-standard-WSL2-x86_64-with-glibc2.35
- Checks: 98 x 5 runtimes
- Invocation: `tests/manual/run_fixtures.py --runtimes wasmtime,wasm3,das,native,aot_ctx`

Runtimes:

- wasmtime: `/root/wasm3das/tools/bin/wasmtime` — wasmtime 48.0.1 (7bac2c277 2026-08-24)
- wasm3 C: `/root/wasm3das/tools/bin/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Sep  9 2026 18:03:13, GCC 11.4.0
- wasm3das(inter): `/root/wasm3das/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(aot): `/root/wasm3das/tmp/native/bin/wasm3das` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(aot_ctx): `/root/wasm3das/tmp/native-ctx/bin/wasm3das` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4

## Skipped entries

- `test_pure/render_frame 0.0` — runs ~400M float iterations; interpreter-in-interpreter would take hours
- `i64 probe_hash_i64_div_*_0/1` — debug probes, need i64 args, no documented baselines
- `host-adapter paths (gltf_rs, cgltf, wasm3, archive-secret extract, lodepng/plmpeg-stream host, lodepng_diag)` — need a Daslang memory-adapter driver, out of scope here
- `real-world-smollm2` — no wasm module built (upstream blocker on tensor callbacks)

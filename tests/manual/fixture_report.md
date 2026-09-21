# Spider manual fixtures: parity and timing

## Основные

По одной продакшен-конфигурации на модуль: самый тяжёлый реальный экспорт (декодер, полный цикл, длинная симуляция). Остальные экспорты и вариации аргументов — справочной таблицей ниже.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `add` 1 2 | 0.092s | 0.001s | 0.982s | 0.948s | 0.015s | 0.743s | 0.024s | ~11x | ~715x |
| `hash_loop` seed 123456789, 200000 итераций | 0.013s | 0.004s | 0.644s | 1.372s | 0.018s | 0.690s | 0.031s | ~48x | ~165x |
| `hash_f32` 2048 элементов | 0.014s | 0.001s | 0.191s | 0.880s | 0.015s | 0.786s | 0.024s | ~14x | ~150x |
| `hash_f64` 2048 элементов | 0.011s | 0.001s | 0.195s | 0.929s | 0.014s | 0.718s | 0.024s | ~18x | ~145x |
| `hash_i64_mix` 512 элементов | 0.015s | 0.001s | 0.182s | 0.889s | 0.014s | 0.713s | 0.024s | ~12x | ~137x |
| `hash_i64_div` 512 элементов | 0.012s | 0.001s | 0.210s | 0.870s | 0.015s | 0.700s | 0.023s | ~17x | ~171x |
| `tinyexpr_hash` 256 выражений | 0.017s | 0.002s | 0.271s | 0.985s | 0.016s | 0.739s | 0.025s | ~16x | ~117x |
| `miniz_roundtrip_hash` уровень 6 | 0.027s | 0.005s | 0.506s | 1.140s | 0.018s | 0.710s | 0.029s | ~19x | ~112x |
| `miniz_full_hash` уровень 6 | 0.030s | 0.011s | 0.613s | 1.262s | 0.019s | 0.741s | 0.032s | ~21x | ~57x |
| `miniz_file_hash` уровень 6 | 0.035s | 0.021s | 0.699s | 1.218s | 0.022s | 0.724s | 0.038s | ~20x | ~34x |
| `lodepng_roundtrip` картинка 1 | 0.037s | 0.026s | 1.614s | 2.187s | 0.030s | 0.770s | 0.049s | ~43x | ~62x |
| `chipmunk_hash_scene` 600 шагов | 0.025s | 0.065s | 5.102s | 5.217s | 0.081s | 0.796s | 0.112s | ~208x | ~79x |
| `secret_expected_crc32` | 0.024s | 0.003s | 0.181s | 0.868s | 0.014s | 0.710s | 0.026s | ~7.4x | ~64x |
| `profile_memory_walk` 400 итераций | 0.025s | 0.007s | 0.881s | 1.468s | 0.020s | 0.735s | 0.034s | ~35x | ~126x |
| `profile_math_shim` 400 итераций | 0.023s | 0.005s | 0.265s | 0.993s | 0.015s | 0.743s | 0.026s | ~12x | ~56x |
| `profile_branch_state` 400 итераций | 0.023s | 0.005s | 0.281s | 0.986s | 0.016s | 0.796s | 0.031s | ~12x | ~61x |
| `profile_space_freefall` 120 шагов | 0.024s | 0.006s | 0.377s | 1.043s | 0.017s | 0.713s | 0.027s | ~16x | ~64x |
| `profile_space_collision` 120 шагов | 0.024s | 0.015s | 1.208s | 1.770s | 0.027s | 0.735s | 0.042s | ~50x | ~81x |
| `profile_space_full` 120 шагов | 0.024s | 0.015s | 1.216s | 1.803s | 0.028s | 0.769s | 0.043s | ~50x | ~80x |
| `h264mp4_decode_hash` 8 кадров | 0.046s | 0.039s | 1.220s | 1.905s | 0.035s | 0.761s | 0.047s | ~27x | ~31x |
| `plmpeg_decode_hash` 8 кадров | 0.032s | 0.077s | 2.016s | 2.242s | 0.037s | 0.728s | 0.056s | ~62x | ~26x |
| `plmpeg_stream_decode_hash` 8 кадров | 0.022s | 0.065s | 2.025s | 2.454s | 0.038s | 0.742s | 0.058s | ~93x | ~31x |
| `libjpeg_decode_hash` | 0.061s | 0.033s | 1.116s | 1.658s | 0.027s | 0.732s | 0.041s | ~18x | ~34x |
| `mjpeg_decode_hash` 12 кадров | 0.067s | 0.047s | 2.309s | 2.663s | 0.038s | 0.736s | 0.068s | ~34x | ~49x |
| `binjgb_decode_hash` 16 кадров | 0.052s | 0.193s | 17.290s | 16.232s | 0.176s | 0.980s | 0.283s | ~330x | ~89x |
| `builder_c0_run_hash` вариант 0 | 0.046s | 0.006s | 0.268s | 0.864s | 0.018s | 0.694s | 0.028s | ~5.8x | ~43x |

| runtime | суммарное время (основные) | × к wasm3 C | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: |
| wasmtime | 0.820s | ~1.3x | 0.545s | ~0.9x |
| wasm3 C | 0.655s | ~1.0x | 0.622s | ~1.0x |
| wasm3das(inter) | 41.863s | ~64x | 36.896s | ~59x |
| wasm3das(aot) | 54.844s | ~84x | 31.957s | ~51x |
| wasm3das(aot_ctx) | 0.782s | ~1.2x | 0.413s | ~0.7x |
| wasm3das(jit) | 19.404s | ~30x | 0.737s | ~1.2x |
| wasm3das(exe) | 1.246s | ~1.9x | 0.632s | ~1.0x |

## Вариации аргументов и остальные экспорты

Справочные строки: остальные экспорты модулей, отладочные пробы и остальные конфигурации аргументов. Методика и колонки те же.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hash_loop` seed 1, 65536 итераций | 0.011s | 0.002s | 0.331s | 1.031s | 0.015s | 0.697s | 0.026s | ~29x | ~162x |
| `probe_div_s64` | 0.012s | 0.001s | 0.199s | 0.812s | 0.014s | 0.770s | 0.024s | ~16x | ~174x |
| `probe_rem_s64` | 0.012s | 0.001s | 0.182s | 0.912s | 0.014s | 0.706s | 0.024s | ~15x | ~148x |
| `probe_div_u64` | 0.013s | 0.001s | 0.187s | 0.933s | 0.014s | 0.771s | 0.024s | ~15x | ~156x |
| `probe_rem_u64` | 0.012s | 0.001s | 0.195s | 1.033s | 0.014s | 0.684s | 0.023s | ~16x | ~139x |
| `tinyexpr_error_code` | 0.016s | 0.001s | 0.184s | 0.991s | 0.015s | 0.713s | 0.025s | ~12x | ~128x |
| `miniz_probe_compressed_size` уровень 6 | 0.025s | 0.004s | 0.398s | 1.143s | 0.018s | 0.752s | 0.027s | ~16x | ~99x |
| `miniz_probe_crc32` | 0.025s | 0.002s | 0.215s | 0.978s | 0.016s | 0.690s | 0.025s | ~8.7x | ~101x |
| `miniz_probe_adler32` | 0.026s | 0.002s | 0.215s | 0.826s | 0.015s | 0.684s | 0.024s | ~8.3x | ~102x |
| `miniz_probe_fold_hash` | 0.029s | 0.002s | 0.214s | 0.878s | 0.015s | 0.700s | 0.026s | ~7.3x | ~94x |
| `miniz_full_num_files` уровень 6 | 0.029s | 0.011s | 0.600s | 1.212s | 0.020s | 0.719s | 0.033s | ~21x | ~54x |
| `miniz_full_archive_size` уровень 6 | 0.034s | 0.011s | 0.594s | 1.147s | 0.020s | 0.804s | 0.034s | ~18x | ~52x |
| `miniz_full_locate_mix` уровень 6 | 0.030s | 0.011s | 0.597s | 1.235s | 0.019s | 0.785s | 0.035s | ~20x | ~54x |
| `miniz_full_extract_hash` уровень 6 | 0.030s | 0.011s | 0.618s | 1.195s | 0.020s | 0.753s | 0.033s | ~21x | ~56x |
| `miniz_full_validate` уровень 6 | 0.031s | 0.012s | 0.591s | 1.088s | 0.020s | 0.831s | 0.034s | ~19x | ~51x |
| `miniz_file_num_files` уровень 6 | 0.031s | 0.020s | 0.709s | 1.276s | 0.022s | 0.701s | 0.035s | ~23x | ~35x |
| `miniz_file_archive_size` уровень 6 | 0.030s | 0.020s | 0.686s | 1.267s | 0.023s | 0.711s | 0.042s | ~23x | ~34x |
| `miniz_file_extract_hash` уровень 6 | 0.031s | 0.021s | 0.700s | 1.220s | 0.022s | 0.701s | 0.036s | ~23x | ~33x |
| `miniz_file_in_place` уровень 6 | 0.029s | 0.020s | 0.693s | 1.239s | 0.023s | 0.755s | 0.037s | ~24x | ~34x |
| `lodepng_roundtrip` картинка 0 | 0.035s | 0.022s | 1.160s | 1.628s | 0.025s | 0.765s | 0.042s | ~33x | ~53x |
| `lodepng_encoded_size` картинка 0 | 0.035s | 0.020s | 0.980s | 1.607s | 0.025s | 0.829s | 0.038s | ~28x | ~50x |
| `lodepng_decode_hash` картинка 0 | 0.036s | 0.022s | 1.151s | 1.645s | 0.025s | 0.726s | 0.042s | ~32x | ~53x |
| `lodepng_input_hash` картинка 0 | 0.032s | 0.013s | 0.209s | 0.894s | 0.017s | 0.747s | 0.030s | ~6.6x | ~16x |
| `lodepng_png_hash` картинка 0 | 0.036s | 0.020s | 1.002s | 1.700s | 0.025s | 0.796s | 0.038s | ~28x | ~49x |
| `lodepng_encoded_size` картинка 1 | 0.033s | 0.024s | 1.364s | 1.842s | 0.027s | 0.735s | 0.044s | ~42x | ~56x |
| `lodepng_decode_hash` картинка 1 | 0.034s | 0.027s | 1.627s | 1.985s | 0.036s | 0.742s | 0.048s | ~48x | ~60x |
| `lodepng_input_hash` картинка 1 | 0.034s | 0.013s | 0.202s | 0.862s | 0.016s | 0.706s | 0.028s | ~6.0x | ~16x |
| `lodepng_png_hash` картинка 1 | 0.035s | 0.023s | 1.361s | 1.921s | 0.028s | 0.724s | 0.043s | ~39x | ~59x |
| `chipmunk_hash_scene` 60 шагов | 0.027s | 0.009s | 0.753s | 1.314s | 0.022s | 0.750s | 0.034s | ~28x | ~80x |
| `chipmunk_variant` 600 шагов | 0.027s | 0.084s | 6.575s | 6.449s | 0.098s | 0.851s | 0.135s | ~247x | ~79x |
| `chipmunk_probe_x` тело 0, 600 шагов | 0.026s | 0.067s | 5.170s | 5.141s | 0.081s | 0.848s | 0.111s | ~196x | ~77x |
| `chipmunk_probe_y` тело 1, 600 шагов | 0.025s | 0.065s | 5.176s | 5.351s | 0.080s | 0.789s | 0.109s | ~205x | ~80x |
| `chipmunk_probe_angle` тело 2, 600 шагов | 0.026s | 0.065s | 5.348s | 5.212s | 0.081s | 0.788s | 0.124s | ~205x | ~83x |
| `secret_expected_length` | 0.025s | 0.003s | 0.181s | 0.942s | 0.015s | 0.711s | 0.024s | ~7.2x | ~72x |
| `h264mp4_width` | 0.039s | 0.028s | 0.470s | 1.221s | 0.023s | 0.724s | 0.033s | ~12x | ~17x |
| `h264mp4_height` | 0.042s | 0.029s | 0.462s | 1.136s | 0.023s | 0.724s | 0.034s | ~11x | ~16x |
| `h264mp4_frame_count` 8 кадров | 0.045s | 0.040s | 1.191s | 1.712s | 0.035s | 0.889s | 0.047s | ~27x | ~30x |
| `h264mp4_first_frame` | 0.044s | 0.028s | 0.469s | 1.021s | 0.024s | 0.890s | 0.035s | ~11x | ~17x |
| `h264mp4_last_frame` 8 кадров | 0.046s | 0.039s | 1.226s | 1.755s | 0.035s | 0.731s | 0.053s | ~27x | ~31x |
| `plmpeg_width` | 0.029s | 0.050s | 0.468s | 1.065s | 0.024s | 0.710s | 0.041s | ~16x | ~9.4x |
| `plmpeg_height` | 0.028s | 0.049s | 0.476s | 1.071s | 0.026s | 0.714s | 0.036s | ~17x | ~9.6x |
| `plmpeg_frame_count` 8 кадров | 0.029s | 0.077s | 2.155s | 2.357s | 0.037s | 0.729s | 0.057s | ~75x | ~28x |
| `plmpeg_first_frame` | 0.027s | 0.053s | 0.478s | 1.139s | 0.024s | 0.713s | 0.038s | ~18x | ~9.0x |
| `plmpeg_last_frame` 8 кадров | 0.030s | 0.065s | 2.093s | 2.423s | 0.037s | 0.898s | 0.058s | ~70x | ~32x |
| `plmpeg_stream_width` | 0.020s | 0.051s | 0.518s | 1.139s | 0.027s | 0.746s | 0.036s | ~26x | ~10x |
| `plmpeg_stream_height` | 0.020s | 0.050s | 0.479s | 1.223s | 0.025s | 0.725s | 0.036s | ~24x | ~9.5x |
| `plmpeg_stream_frame_count` 8 кадров | 0.021s | 0.065s | 1.977s | 2.483s | 0.038s | 0.856s | 0.057s | ~93x | ~31x |
| `plmpeg_stream_first_frame` | 0.021s | 0.050s | 0.478s | 1.132s | 0.025s | 0.738s | 0.038s | ~23x | ~9.6x |
| `plmpeg_stream_last_frame` 8 кадров | 0.020s | 0.065s | 2.034s | 2.511s | 0.039s | 0.734s | 0.058s | ~101x | ~31x |
| `libjpeg_width` | 0.058s | 0.033s | 0.915s | 1.450s | 0.026s | 0.831s | 0.044s | ~16x | ~27x |
| `libjpeg_height` | 0.067s | 0.033s | 0.973s | 1.566s | 0.027s | 0.795s | 0.040s | ~15x | ~29x |
| `libjpeg_components` | 0.059s | 0.034s | 0.972s | 1.528s | 0.026s | 0.781s | 0.041s | ~16x | ~29x |
| `libjpeg_input_hash` | 0.059s | 0.024s | 0.205s | 0.877s | 0.018s | 0.798s | 0.030s | ~3.5x | ~8.4x |
| `libjpeg_rgb_size` | 0.060s | 0.037s | 0.943s | 1.560s | 0.026s | 0.728s | 0.049s | ~16x | ~26x |
| `mjpeg_width` | 0.059s | 0.029s | 0.405s | 1.064s | 0.021s | 0.723s | 0.033s | ~6.9x | ~14x |
| `mjpeg_height` | 0.063s | 0.027s | 0.510s | 0.997s | 0.021s | 0.858s | 0.032s | ~8.1x | ~19x |
| `mjpeg_components` | 0.059s | 0.027s | 0.403s | 0.993s | 0.025s | 0.748s | 0.035s | ~6.8x | ~15x |
| `mjpeg_frame_count` 12 кадров | 0.058s | 0.047s | 2.420s | 2.733s | 0.048s | 0.800s | 0.063s | ~42x | ~52x |
| `mjpeg_first_frame` | 0.059s | 0.027s | 0.428s | 1.030s | 0.024s | 0.725s | 0.035s | ~7.3x | ~16x |
| `mjpeg_last_frame` 12 кадров | 0.058s | 0.049s | 2.323s | 2.740s | 0.040s | 0.745s | 0.060s | ~40x | ~47x |
| `mjpeg_input_hash` | 0.056s | 0.028s | 0.212s | 0.916s | 0.018s | 0.751s | 0.032s | ~3.8x | ~7.6x |
| `binjgb_width` | 0.042s | 0.046s | 0.187s | 0.801s | 0.021s | 0.695s | 0.031s | ~4.5x | ~4.0x |
| `binjgb_height` | 0.039s | 0.046s | 0.187s | 0.817s | 0.021s | 0.698s | 0.032s | ~4.8x | ~4.0x |
| `binjgb_frame_count` 16 кадров | 0.050s | 0.204s | 17.449s | 16.038s | 0.176s | 1.254s | 0.289s | ~351x | ~85x |
| `binjgb_first_frame` | 0.042s | 0.056s | 1.262s | 1.654s | 0.032s | 0.728s | 0.049s | ~30x | ~23x |
| `binjgb_last_frame` 16 кадров | 0.049s | 0.192s | 17.440s | 15.577s | 0.172s | 1.003s | 0.306s | ~356x | ~91x |
| `builder_case_count` | 0.047s | 0.005s | 0.185s | 0.891s | 0.015s | 0.766s | 0.026s | ~4.0x | ~39x |
| `builder_c0_code_hash` вариант 0 | 0.047s | 0.006s | 0.278s | 0.856s | 0.018s | 0.688s | 0.027s | ~6.0x | ~44x |
| `builder_c1_code_hash` вариант 1 | 0.045s | 0.006s | 0.352s | 0.896s | 0.018s | 0.786s | 0.029s | ~7.8x | ~57x |
| `builder_c1_run_hash` вариант 1 | 0.049s | 0.007s | 0.287s | 0.858s | 0.018s | 0.742s | 0.028s | ~5.9x | ~44x |
| `builder_c2_code_hash` вариант 2 | 0.052s | 0.007s | 0.297s | 0.894s | 0.018s | 0.743s | 0.028s | ~5.7x | ~42x |
| `builder_c2_run_hash` вариант 2 | 0.048s | 0.007s | 0.298s | 0.857s | 0.018s | 0.766s | 0.029s | ~6.2x | ~42x |

Все результаты совпали с baseline (wasmtime 86/86, wasm3 C 86/86, wasm3das(inter) 86/86, wasm3das(aot) 86/86, wasm3das(aot_ctx) 86/86, wasm3das(jit) 86/86, wasm3das(exe) 86/86)

Ещё 12 строк(и) без документированного baseline остаются в таблице, их результат не проверяется.

## Итого (весь набор: основные + вариации)

| runtime | суммарное время | × к wasm3 C | старт (`fixtures/add`) | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasmtime | 3.421s | ~1.1x | 0.011s | 2.385s | ~0.8x |
| wasm3 C | 3.004s | ~1.0x | 0.001s | 2.879s | ~1.0x |
| wasm3das(inter) | 2m26.1s | ~49x | 0.191s | 2m07.4s | ~44x |
| wasm3das(aot) | 3m14.7s | ~65x | 0.880s | 1m48.5s | ~38x |
| wasm3das(aot_ctx) | 3.012s | ~1.0x | 0.014s | 1.618s | ~0.6x |
| wasm3das(jit) | 1m14.5s | ~25x | 0.718s | 4.155s | ~1.4x |
| wasm3das(exe) | 4.725s | ~1.6x | 0.024s | 2.410s | ~0.8x |

Старт это минимальное полное время среди строк без исполнения (`add`, `hash_f32`, `hash_f64`), «без старта» это сумма минус старт на каждую засчитанную строку: оценка рядом с честным полным временем, не вместо него.

## Прогон

- Date (UTC): 2026-09-21T23:30:46Z
- Machine: AMD Ryzen 7 7435HS (16 logical CPUs)
- Platform: Linux-6.6.87.2-microsoft-standard-WSL2-x86_64-with-glibc2.35
- Checks: 98 x 7 runtimes
- Invocation: `tests/manual/run_fixtures.py --runtimes wasmtime,wasm3,das,native,aot_ctx,jit,exe`

Runtimes:

- wasmtime: `/tmp/claude-0/-root-wasm3das/4156561e-0531-41d3-969e-c280e71c542b/scratchpad/agentP/wt/tools/bin/wasmtime` — wasmtime 48.0.1 (7bac2c277 2026-08-24)
- wasm3 C: `/tmp/claude-0/-root-wasm3das/4156561e-0531-41d3-969e-c280e71c542b/scratchpad/agentP/wt/tools/bin/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Sep  9 2026 18:03:13, GCC 11.4.0
- wasm3das(inter): `/tmp/claude-0/-root-wasm3das/4156561e-0531-41d3-969e-c280e71c542b/scratchpad/agentP/wt/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(aot): `/tmp/claude-0/-root-wasm3das/4156561e-0531-41d3-969e-c280e71c542b/scratchpad/agentP/wt/tmp/native/bin/wasm3das` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(aot_ctx): `/tmp/claude-0/-root-wasm3das/4156561e-0531-41d3-969e-c280e71c542b/scratchpad/agentP/wt/tmp/native-ctx/bin/wasm3das` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(jit): `DASLANG=/root/daScript/bin/daslang WASM3DAS_JIT=1 WASM3DAS_JIT_OPTS=--jit-opt-level=3 /tmp/claude-0/-root-wasm3das/4156561e-0531-41d3-969e-c280e71c542b/scratchpad/agentP/wt/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(exe): `/tmp/claude-0/-root-wasm3das/4156561e-0531-41d3-969e-c280e71c542b/scratchpad/agentP/wt/scripts/wasm3-exe` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4

## Skipped entries

- `test_pure/render_frame 0.0` — runs ~400M float iterations; interpreter-in-interpreter would take hours
- `i64 probe_hash_i64_div_*_0/1` — debug probes, need i64 args, no documented baselines
- `host-adapter paths (gltf_rs, cgltf, wasm3, archive-secret extract, lodepng/plmpeg-stream host, lodepng_diag)` — need a Daslang memory-adapter driver, out of scope here
- `real-world-smollm2` — no wasm module built (upstream blocker on tensor callbacks)

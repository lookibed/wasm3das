# Spider manual fixtures: parity and timing

## Основные

По одной продакшен-конфигурации на модуль: самый тяжёлый реальный экспорт (декодер, полный цикл, длинная симуляция). Остальные экспорты и вариации аргументов — справочной таблицей ниже.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `add` 1 2 | 0.010s | 0.001s | 0.209s | 0.683s | 0.013s | 0.697s | 0.017s | ~20x | ~140x |
| `hash_loop` seed 123456789, 200000 итераций | 0.010s | 0.004s | 0.657s | 1.157s | 0.017s | 0.746s | 0.025s | ~64x | ~165x |
| `hash_f32` 2048 элементов | 0.011s | 0.001s | 0.194s | 0.707s | 0.014s | 0.675s | 0.019s | ~18x | ~150x |
| `hash_f64` 2048 элементов | 0.010s | 0.001s | 0.193s | 0.745s | 0.014s | 0.671s | 0.017s | ~18x | ~132x |
| `hash_i64_mix` 512 элементов | 0.012s | 0.001s | 0.185s | 0.802s | 0.015s | 0.672s | 0.018s | ~16x | ~130x |
| `hash_i64_div` 512 элементов | 0.012s | 0.001s | 0.193s | 0.801s | 0.014s | 0.722s | 0.018s | ~16x | ~158x |
| `tinyexpr_hash` 256 выражений | 0.016s | 0.002s | 0.269s | 0.855s | 0.016s | 0.681s | 0.020s | ~17x | ~109x |
| `miniz_roundtrip_hash` уровень 6 | 0.026s | 0.005s | 0.474s | 1.096s | 0.018s | 0.675s | 0.024s | ~18x | ~104x |
| `miniz_full_hash` уровень 6 | 0.029s | 0.011s | 0.566s | 1.049s | 0.020s | 0.754s | 0.026s | ~20x | ~52x |
| `miniz_file_hash` уровень 6 | 0.031s | 0.024s | 0.677s | 1.177s | 0.023s | 0.697s | 0.030s | ~22x | ~28x |
| `lodepng_roundtrip` картинка 1 | 0.034s | 0.026s | 1.694s | 2.040s | 0.032s | 0.727s | 0.041s | ~50x | ~66x |
| `chipmunk_hash_scene` 600 шагов | 0.024s | 0.064s | 4.980s | 5.332s | 0.080s | 0.771s | 0.102s | ~207x | ~77x |
| `secret_expected_crc32` | 0.025s | 0.002s | 0.185s | 0.800s | 0.014s | 0.676s | 0.017s | ~7.4x | ~75x |
| `profile_memory_walk` 400 итераций | 0.024s | 0.007s | 0.890s | 1.358s | 0.019s | 0.686s | 0.027s | ~38x | ~130x |
| `profile_math_shim` 400 итераций | 0.022s | 0.005s | 0.239s | 0.762s | 0.016s | 0.713s | 0.020s | ~11x | ~51x |
| `profile_branch_state` 400 итераций | 0.022s | 0.004s | 0.275s | 0.847s | 0.015s | 0.694s | 0.019s | ~13x | ~62x |
| `profile_space_freefall` 120 шагов | 0.023s | 0.006s | 0.387s | 0.969s | 0.017s | 0.712s | 0.021s | ~17x | ~66x |
| `profile_space_collision` 120 шагов | 0.023s | 0.015s | 1.117s | 1.698s | 0.026s | 0.780s | 0.036s | ~48x | ~77x |
| `profile_space_full` 120 шагов | 0.026s | 0.015s | 1.113s | 1.608s | 0.027s | 0.732s | 0.036s | ~42x | ~76x |
| `h264mp4_decode_hash` 8 кадров | 0.041s | 0.038s | 1.177s | 1.697s | 0.033s | 0.717s | 0.041s | ~28x | ~31x |
| `plmpeg_decode_hash` 8 кадров | 0.028s | 0.062s | 1.916s | 2.328s | 0.036s | 0.710s | 0.050s | ~67x | ~31x |
| `plmpeg_stream_decode_hash` 8 кадров | 0.019s | 0.068s | 1.903s | 2.350s | 0.037s | 0.828s | 0.051s | ~99x | ~28x |
| `libjpeg_decode_hash` | 0.059s | 0.032s | 1.020s | 1.516s | 0.027s | 0.750s | 0.037s | ~17x | ~32x |
| `mjpeg_decode_hash` 12 кадров | 0.065s | 0.046s | 2.351s | 2.735s | 0.040s | 0.772s | 0.056s | ~36x | ~51x |
| `binjgb_decode_hash` 16 кадров | 0.055s | 0.227s | 18.463s | 16.844s | 0.198s | 0.976s | 0.275s | ~335x | ~81x |
| `builder_c0_run_hash` вариант 0 | 0.049s | 0.007s | 0.279s | 0.997s | 0.019s | 0.907s | 0.022s | ~5.7x | ~43x |

| runtime | суммарное время (основные) | × к wasm3 C | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: |
| wasmtime | 0.707s | ~1.0x | 0.438s | ~0.7x |
| wasm3 C | 0.676s | ~1.0x | 0.642s | ~1.0x |
| wasm3das(inter) | 41.608s | ~62x | 36.579s | ~57x |
| wasm3das(aot) | 52.954s | ~78x | 35.188s | ~55x |
| wasm3das(aot_ctx) | 0.798s | ~1.2x | 0.450s | ~0.7x |
| wasm3das(jit) | 19.141s | ~28x | 1.688s | ~2.6x |
| wasm3das(exe) | 1.065s | ~1.6x | 0.623s | ~1.0x |

## Вариации аргументов и остальные экспорты

Справочные строки: остальные экспорты модулей, отладочные пробы и остальные конфигурации аргументов. Методика и колонки те же.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hash_loop` seed 1, 65536 итераций | 0.010s | 0.002s | 0.356s | 0.868s | 0.015s | 0.693s | 0.020s | ~35x | ~156x |
| `probe_div_s64` | 0.012s | 0.001s | 0.197s | 0.820s | 0.014s | 0.691s | 0.018s | ~16x | ~134x |
| `probe_rem_s64` | 0.012s | 0.001s | 0.177s | 0.872s | 0.014s | 0.697s | 0.018s | ~15x | ~145x |
| `probe_div_u64` | 0.012s | 0.001s | 0.177s | 0.840s | 0.014s | 0.679s | 0.018s | ~15x | ~154x |
| `probe_rem_u64` | 0.012s | 0.001s | 0.179s | 0.820s | 0.014s | 0.670s | 0.017s | ~15x | ~145x |
| `tinyexpr_error_code` | 0.016s | 0.002s | 0.181s | 0.797s | 0.015s | 0.685s | 0.019s | ~11x | ~116x |
| `miniz_probe_compressed_size` уровень 6 | 0.025s | 0.004s | 0.392s | 0.906s | 0.016s | 0.711s | 0.022s | ~16x | ~96x |
| `miniz_probe_crc32` | 0.025s | 0.002s | 0.208s | 0.780s | 0.015s | 0.672s | 0.019s | ~8.4x | ~98x |
| `miniz_probe_adler32` | 0.025s | 0.002s | 0.203s | 0.850s | 0.016s | 0.674s | 0.019s | ~8.1x | ~94x |
| `miniz_probe_fold_hash` | 0.025s | 0.002s | 0.203s | 0.813s | 0.015s | 0.671s | 0.020s | ~8.0x | ~91x |
| `miniz_full_num_files` уровень 6 | 0.028s | 0.011s | 0.578s | 1.022s | 0.019s | 0.736s | 0.026s | ~20x | ~52x |
| `miniz_full_archive_size` уровень 6 | 0.030s | 0.011s | 0.605s | 1.036s | 0.020s | 0.751s | 0.026s | ~20x | ~54x |
| `miniz_full_locate_mix` уровень 6 | 0.029s | 0.011s | 0.592s | 1.068s | 0.020s | 0.708s | 0.026s | ~21x | ~56x |
| `miniz_full_extract_hash` уровень 6 | 0.029s | 0.011s | 0.561s | 1.024s | 0.020s | 0.676s | 0.025s | ~20x | ~51x |
| `miniz_full_validate` уровень 6 | 0.032s | 0.011s | 0.608s | 1.062s | 0.020s | 0.678s | 0.026s | ~19x | ~56x |
| `miniz_file_num_files` уровень 6 | 0.035s | 0.021s | 0.754s | 1.310s | 0.022s | 0.695s | 0.029s | ~22x | ~36x |
| `miniz_file_archive_size` уровень 6 | 0.031s | 0.020s | 0.679s | 1.180s | 0.022s | 0.697s | 0.030s | ~22x | ~33x |
| `miniz_file_extract_hash` уровень 6 | 0.032s | 0.020s | 0.698s | 1.262s | 0.022s | 0.719s | 0.031s | ~22x | ~35x |
| `miniz_file_in_place` уровень 6 | 0.035s | 0.020s | 0.675s | 1.183s | 0.022s | 0.698s | 0.030s | ~19x | ~33x |
| `lodepng_roundtrip` картинка 0 | 0.034s | 0.022s | 1.088s | 1.657s | 0.026s | 0.709s | 0.035s | ~32x | ~50x |
| `lodepng_encoded_size` картинка 0 | 0.036s | 0.020s | 0.957s | 1.495s | 0.024s | 0.703s | 0.033s | ~27x | ~48x |
| `lodepng_decode_hash` картинка 0 | 0.032s | 0.021s | 1.070s | 1.642s | 0.025s | 0.715s | 0.036s | ~33x | ~50x |
| `lodepng_input_hash` картинка 0 | 0.034s | 0.012s | 0.197s | 0.926s | 0.017s | 0.734s | 0.020s | ~5.7x | ~16x |
| `lodepng_png_hash` картинка 0 | 0.035s | 0.020s | 0.952s | 1.555s | 0.024s | 0.691s | 0.032s | ~27x | ~48x |
| `lodepng_encoded_size` картинка 1 | 0.034s | 0.024s | 1.322s | 1.833s | 0.027s | 0.716s | 0.037s | ~39x | ~56x |
| `lodepng_decode_hash` картинка 1 | 0.035s | 0.026s | 1.519s | 1.985s | 0.029s | 0.794s | 0.042s | ~43x | ~58x |
| `lodepng_input_hash` картинка 1 | 0.037s | 0.013s | 0.210s | 0.814s | 0.016s | 0.695s | 0.021s | ~5.7x | ~17x |
| `lodepng_png_hash` картинка 1 | 0.033s | 0.023s | 1.305s | 1.855s | 0.026s | 0.734s | 0.038s | ~40x | ~56x |
| `chipmunk_hash_scene` 60 шагов | 0.022s | 0.009s | 0.700s | 1.416s | 0.021s | 0.696s | 0.035s | ~31x | ~74x |
| `chipmunk_variant` 600 шагов | 0.026s | 0.094s | 6.527s | 6.537s | 0.097s | 0.823s | 0.124s | ~250x | ~70x |
| `chipmunk_probe_x` тело 0, 600 шагов | 0.025s | 0.065s | 4.975s | 5.300s | 0.080s | 0.757s | 0.101s | ~203x | ~76x |
| `chipmunk_probe_y` тело 1, 600 шагов | 0.026s | 0.070s | 5.135s | 5.061s | 0.079s | 0.826s | 0.103s | ~197x | ~74x |
| `chipmunk_probe_angle` тело 2, 600 шагов | 0.025s | 0.064s | 5.339s | 5.255s | 0.081s | 0.802s | 0.104s | ~211x | ~83x |
| `secret_expected_length` | 0.024s | 0.003s | 0.187s | 0.734s | 0.014s | 0.723s | 0.019s | ~7.7x | ~73x |
| `h264mp4_width` | 0.040s | 0.027s | 0.481s | 0.945s | 0.022s | 0.808s | 0.031s | ~12x | ~18x |
| `h264mp4_height` | 0.042s | 0.028s | 0.472s | 1.031s | 0.023s | 0.696s | 0.027s | ~11x | ~17x |
| `h264mp4_frame_count` 8 кадров | 0.042s | 0.039s | 1.254s | 1.722s | 0.033s | 0.709s | 0.041s | ~30x | ~32x |
| `h264mp4_first_frame` | 0.040s | 0.027s | 0.453s | 0.982s | 0.022s | 0.744s | 0.027s | ~11x | ~17x |
| `h264mp4_last_frame` 8 кадров | 0.042s | 0.041s | 1.201s | 1.676s | 0.033s | 0.699s | 0.040s | ~29x | ~29x |
| `plmpeg_width` | 0.027s | 0.047s | 0.465s | 1.163s | 0.024s | 0.767s | 0.029s | ~17x | ~9.9x |
| `plmpeg_height` | 0.027s | 0.050s | 0.461s | 1.027s | 0.025s | 0.686s | 0.029s | ~17x | ~9.3x |
| `plmpeg_frame_count` 8 кадров | 0.029s | 0.062s | 1.900s | 2.373s | 0.037s | 0.758s | 0.050s | ~65x | ~31x |
| `plmpeg_first_frame` | 0.027s | 0.049s | 0.468s | 1.217s | 0.025s | 0.695s | 0.029s | ~17x | ~9.6x |
| `plmpeg_last_frame` 8 кадров | 0.029s | 0.062s | 1.993s | 2.220s | 0.037s | 0.702s | 0.050s | ~68x | ~32x |
| `plmpeg_stream_width` | 0.019s | 0.052s | 0.462s | 1.037s | 0.024s | 0.684s | 0.029s | ~24x | ~9.0x |
| `plmpeg_stream_height` | 0.019s | 0.046s | 0.561s | 1.004s | 0.024s | 0.791s | 0.033s | ~30x | ~12x |
| `plmpeg_stream_frame_count` 8 кадров | 0.021s | 0.062s | 2.061s | 2.224s | 0.037s | 0.707s | 0.050s | ~100x | ~33x |
| `plmpeg_stream_first_frame` | 0.022s | 0.047s | 0.524s | 1.061s | 0.025s | 0.703s | 0.030s | ~23x | ~11x |
| `plmpeg_stream_last_frame` 8 кадров | 0.021s | 0.060s | 2.031s | 2.319s | 0.037s | 0.850s | 0.051s | ~98x | ~34x |
| `libjpeg_width` | 0.067s | 0.032s | 0.965s | 1.412s | 0.026s | 0.779s | 0.033s | ~14x | ~30x |
| `libjpeg_height` | 0.059s | 0.031s | 0.939s | 1.384s | 0.027s | 0.911s | 0.034s | ~16x | ~30x |
| `libjpeg_components` | 0.061s | 0.032s | 0.986s | 1.484s | 0.027s | 0.831s | 0.033s | ~16x | ~30x |
| `libjpeg_input_hash` | 0.063s | 0.024s | 0.192s | 0.841s | 0.019s | 0.687s | 0.022s | ~3.0x | ~8.1x |
| `libjpeg_rgb_size` | 0.061s | 0.033s | 0.925s | 1.523s | 0.029s | 0.800s | 0.033s | ~15x | ~28x |
| `mjpeg_width` | 0.060s | 0.027s | 0.392s | 1.013s | 0.021s | 0.797s | 0.026s | ~6.6x | ~15x |
| `mjpeg_height` | 0.057s | 0.026s | 0.388s | 0.890s | 0.023s | 0.751s | 0.026s | ~6.8x | ~15x |
| `mjpeg_components` | 0.058s | 0.029s | 0.438s | 0.915s | 0.021s | 0.761s | 0.026s | ~7.6x | ~15x |
| `mjpeg_frame_count` 12 кадров | 0.059s | 0.045s | 2.396s | 2.683s | 0.038s | 0.823s | 0.056s | ~40x | ~53x |
| `mjpeg_first_frame` | 0.061s | 0.026s | 0.431s | 0.975s | 0.021s | 0.757s | 0.027s | ~7.1x | ~17x |
| `mjpeg_last_frame` 12 кадров | 0.064s | 0.044s | 2.335s | 2.777s | 0.039s | 0.724s | 0.055s | ~36x | ~53x |
| `mjpeg_input_hash` | 0.060s | 0.025s | 0.216s | 0.921s | 0.022s | 0.746s | 0.023s | ~3.6x | ~8.7x |
| `binjgb_width` | 0.045s | 0.041s | 0.180s | 0.839s | 0.022s | 0.736s | 0.029s | ~4.0x | ~4.3x |
| `binjgb_height` | 0.042s | 0.043s | 0.185s | 0.816s | 0.022s | 0.731s | 0.029s | ~4.4x | ~4.3x |
| `binjgb_frame_count` 16 кадров | 0.050s | 0.190s | 18.008s | 16.431s | 0.177s | 1.020s | 0.282s | ~360x | ~95x |
| `binjgb_first_frame` | 0.043s | 0.052s | 1.246s | 1.858s | 0.035s | 0.740s | 0.044s | ~29x | ~24x |
| `binjgb_last_frame` 16 кадров | 0.052s | 0.208s | 18.130s | 16.643s | 0.172s | 1.055s | 0.278s | ~350x | ~87x |
| `builder_case_count` | 0.047s | 0.006s | 0.177s | 0.849s | 0.016s | 0.794s | 0.019s | ~3.7x | ~30x |
| `builder_c0_code_hash` вариант 0 | 0.049s | 0.006s | 0.268s | 0.860s | 0.020s | 0.743s | 0.023s | ~5.4x | ~44x |
| `builder_c1_code_hash` вариант 1 | 0.052s | 0.007s | 0.280s | 0.832s | 0.019s | 0.856s | 0.022s | ~5.4x | ~42x |
| `builder_c1_run_hash` вариант 1 | 0.052s | 0.007s | 0.310s | 1.028s | 0.018s | 0.778s | 0.022s | ~5.9x | ~46x |
| `builder_c2_code_hash` вариант 2 | 0.052s | 0.007s | 0.288s | 0.974s | 0.018s | 0.748s | 0.023s | ~5.5x | ~42x |
| `builder_c2_run_hash` вариант 2 | 0.060s | 0.007s | 0.315s | 1.148s | 0.020s | 0.926s | 0.025s | ~5.3x | ~44x |

Все результаты совпали с baseline (wasmtime 86/86, wasm3 C 86/86, wasm3das(inter) 86/86, wasm3das(aot) 86/86, wasm3das(aot_ctx) 86/86, wasm3das(jit) 86/86, wasm3das(exe) 86/86)

Ещё 12 строк(и) без документированного baseline остаются в таблице, их результат не проверяется.

## Итого (весь набор: основные + вариации)

| runtime | суммарное время | × к wasm3 C | старт (`fixtures/add`) | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasmtime | 3.344s | ~1.1x | 0.010s | 2.330s | ~0.8x |
| wasm3 C | 2.965s | ~1.0x | 0.001s | 2.838s | ~1.0x |
| wasm3das(inter) | 2m25.9s | ~49x | 0.193s | 2m06.9s | ~45x |
| wasm3das(aot) | 3m10.6s | ~64x | 0.683s | 2m03.7s | ~44x |
| wasm3das(aot_ctx) | 2.995s | ~1.0x | 0.013s | 1.682s | ~0.6x |
| wasm3das(jit) | 1m13.0s | ~25x | 0.671s | 7.171s | ~2.5x |
| wasm3das(exe) | 4.019s | ~1.4x | 0.017s | 2.354s | ~0.8x |

Старт это минимальное полное время среди строк без исполнения (`add`, `hash_f32`, `hash_f64`), «без старта» это сумма минус старт на каждую засчитанную строку: оценка рядом с честным полным временем, не вместо него.

## Прогон

- Date (UTC): 2026-09-22T20:54:58Z
- Machine: AMD Ryzen 7 7435HS (16 logical CPUs)
- Platform: Linux-6.6.87.2-microsoft-standard-WSL2-x86_64-with-glibc2.35
- Checks: 98 x 7 runtimes
- Invocation: `tests/manual/run_fixtures.py --runtimes wasmtime,wasm3,das,native,aot_ctx,jit,exe`

Runtimes:

- wasmtime: `/root/wasm3das/tools/bin/wasmtime` — wasmtime 48.0.1 (7bac2c277 2026-08-24)
- wasm3 C: `/root/wasm3das/tools/bin/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Sep  9 2026 18:03:13, GCC 11.4.0
- wasm3das(inter): `/root/wasm3das/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(aot): `/root/wasm3das/tmp/native/bin/wasm3das` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(aot_ctx): `/root/wasm3das/tmp/native-ctx/bin/wasm3das` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(jit): `DASLANG=/root/daScript/bin/daslang WASM3DAS_JIT=1 WASM3DAS_JIT_OPTS=--jit-opt-level=3 /root/wasm3das/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4
- wasm3das(exe): `/root/wasm3das/scripts/wasm3-exe` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4

## Skipped entries

- `test_pure/render_frame 0.0` — runs ~400M float iterations; interpreter-in-interpreter would take hours
- `i64 probe_hash_i64_div_*_0/1` — debug probes, need i64 args, no documented baselines
- `host-adapter paths (gltf_rs, cgltf, wasm3, archive-secret extract, lodepng/plmpeg-stream host, lodepng_diag)` — need a Daslang memory-adapter driver, out of scope here
- `real-world-smollm2` — no wasm module built (upstream blocker on tensor callbacks)

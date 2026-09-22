# Spider manual fixtures: parity and timing

## Основные

По одной продакшен-конфигурации на модуль: самый тяжёлый реальный экспорт (декодер, полный цикл, длинная симуляция). Остальные экспорты и вариации аргументов — справочной таблицей ниже.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `add` 1 2 | 0.066s | 0.001s | 1.100s | 0.938s | 0.014s | 2.305s | 0.018s | ~17x | ~943x |
| `hash_loop` seed 123456789, 200000 итераций | 0.013s | 0.004s | 0.686s | 1.210s | 0.018s | 0.699s | 0.024s | ~53x | ~179x |
| `hash_f32` 2048 элементов | 0.028s | 0.001s | 0.195s | 0.820s | 0.014s | 0.769s | 0.018s | ~6.8x | ~140x |
| `hash_f64` 2048 элементов | 0.010s | 0.001s | 0.196s | 0.778s | 0.014s | 0.691s | 0.018s | ~19x | ~145x |
| `hash_i64_mix` 512 элементов | 0.012s | 0.001s | 0.190s | 0.921s | 0.015s | 0.706s | 0.017s | ~16x | ~155x |
| `hash_i64_div` 512 элементов | 0.012s | 0.001s | 0.184s | 0.949s | 0.014s | 0.697s | 0.018s | ~16x | ~135x |
| `tinyexpr_hash` 256 выражений | 0.017s | 0.003s | 0.277s | 0.889s | 0.016s | 0.706s | 0.020s | ~17x | ~110x |
| `miniz_roundtrip_hash` уровень 6 | 0.026s | 0.005s | 0.496s | 1.011s | 0.018s | 0.824s | 0.024s | ~19x | ~100x |
| `miniz_full_hash` уровень 6 | 0.029s | 0.011s | 0.587s | 1.161s | 0.020s | 0.742s | 0.027s | ~20x | ~54x |
| `miniz_file_hash` уровень 6 | 0.031s | 0.021s | 0.718s | 1.188s | 0.023s | 0.712s | 0.031s | ~23x | ~34x |
| `lodepng_roundtrip` картинка 1 | 0.032s | 0.025s | 1.538s | 2.073s | 0.029s | 0.712s | 0.041s | ~49x | ~61x |
| `chipmunk_hash_scene` 600 шагов | 0.025s | 0.066s | 5.172s | 5.410s | 0.081s | 0.780s | 0.103s | ~210x | ~79x |
| `secret_expected_crc32` | 0.024s | 0.003s | 0.178s | 0.868s | 0.015s | 0.700s | 0.018s | ~7.4x | ~67x |
| `profile_memory_walk` 400 итераций | 0.024s | 0.007s | 0.828s | 1.374s | 0.019s | 0.720s | 0.026s | ~35x | ~123x |
| `profile_math_shim` 400 итераций | 0.023s | 0.004s | 0.248s | 0.878s | 0.015s | 0.693s | 0.019s | ~11x | ~55x |
| `profile_branch_state` 400 итераций | 0.023s | 0.005s | 0.276s | 0.959s | 0.015s | 0.717s | 0.026s | ~12x | ~61x |
| `profile_space_freefall` 120 шагов | 0.027s | 0.007s | 0.364s | 1.018s | 0.017s | 0.714s | 0.021s | ~13x | ~55x |
| `profile_space_collision` 120 шагов | 0.023s | 0.015s | 1.175s | 1.777s | 0.027s | 0.718s | 0.037s | ~50x | ~81x |
| `profile_space_full` 120 шагов | 0.023s | 0.015s | 1.176s | 1.852s | 0.027s | 0.765s | 0.036s | ~51x | ~79x |
| `h264mp4_decode_hash` 8 кадров | 0.044s | 0.039s | 1.200s | 1.664s | 0.034s | 0.750s | 0.040s | ~27x | ~31x |
| `plmpeg_decode_hash` 8 кадров | 0.030s | 0.064s | 1.946s | 2.425s | 0.042s | 0.774s | 0.051s | ~65x | ~30x |
| `plmpeg_stream_decode_hash` 8 кадров | 0.022s | 0.064s | 1.980s | 2.409s | 0.037s | 0.730s | 0.055s | ~91x | ~31x |
| `libjpeg_decode_hash` | 0.064s | 0.032s | 1.059s | 1.673s | 0.026s | 0.695s | 0.034s | ~16x | ~33x |
| `mjpeg_decode_hash` 12 кадров | 0.059s | 0.047s | 2.278s | 2.726s | 0.042s | 0.767s | 0.053s | ~39x | ~49x |
| `binjgb_decode_hash` 16 кадров | 0.051s | 0.193s | 17.789s | 16.195s | 0.174s | 0.988s | 0.281s | ~349x | ~92x |
| `builder_c0_run_hash` вариант 0 | 0.046s | 0.007s | 0.338s | 0.924s | 0.018s | 0.696s | 0.022s | ~7.3x | ~50x |

| runtime | суммарное время (основные) | × к wasm3 C | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: |
| wasmtime | 0.783s | ~1.2x | 0.512s | ~0.8x |
| wasm3 C | 0.641s | ~1.0x | 0.611s | ~1.0x |
| wasm3das(inter) | 42.174s | ~66x | 37.112s | ~61x |
| wasm3das(aot) | 54.088s | ~84x | 33.863s | ~55x |
| wasm3das(aot_ctx) | 0.785s | ~1.2x | 0.415s | ~0.7x |
| wasm3das(jit) | 20.770s | ~32x | 2.802s | ~4.6x |
| wasm3das(exe) | 1.079s | ~1.7x | 0.623s | ~1.0x |

## Вариации аргументов и остальные экспорты

Справочные строки: остальные экспорты модулей, отладочные пробы и остальные конфигурации аргументов. Методика и колонки те же.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hash_loop` seed 1, 65536 итераций | 0.010s | 0.002s | 0.339s | 0.966s | 0.015s | 0.692s | 0.020s | ~32x | ~163x |
| `probe_div_s64` | 0.012s | 0.001s | 0.182s | 0.780s | 0.014s | 0.708s | 0.017s | ~15x | ~149x |
| `probe_rem_s64` | 0.012s | 0.001s | 0.179s | 0.938s | 0.014s | 0.704s | 0.017s | ~15x | ~138x |
| `probe_div_u64` | 0.012s | 0.001s | 0.205s | 0.800s | 0.015s | 0.686s | 0.017s | ~17x | ~177x |
| `probe_rem_u64` | 0.012s | 0.001s | 0.196s | 0.870s | 0.014s | 0.719s | 0.018s | ~17x | ~134x |
| `tinyexpr_error_code` | 0.016s | 0.002s | 0.191s | 0.802s | 0.014s | 0.700s | 0.018s | ~12x | ~115x |
| `miniz_probe_compressed_size` уровень 6 | 0.025s | 0.004s | 0.402s | 1.044s | 0.017s | 0.694s | 0.022s | ~16x | ~105x |
| `miniz_probe_crc32` | 0.025s | 0.002s | 0.229s | 0.864s | 0.016s | 0.695s | 0.019s | ~9.2x | ~112x |
| `miniz_probe_adler32` | 0.024s | 0.002s | 0.216s | 0.889s | 0.015s | 0.740s | 0.019s | ~8.9x | ~107x |
| `miniz_probe_fold_hash` | 0.025s | 0.002s | 0.210s | 0.781s | 0.015s | 0.775s | 0.019s | ~8.4x | ~103x |
| `miniz_full_num_files` уровень 6 | 0.030s | 0.011s | 0.577s | 1.190s | 0.019s | 0.728s | 0.025s | ~19x | ~53x |
| `miniz_full_archive_size` уровень 6 | 0.028s | 0.011s | 0.640s | 1.057s | 0.020s | 0.694s | 0.025s | ~23x | ~60x |
| `miniz_full_locate_mix` уровень 6 | 0.029s | 0.011s | 0.596s | 1.177s | 0.020s | 0.698s | 0.026s | ~21x | ~56x |
| `miniz_full_extract_hash` уровень 6 | 0.031s | 0.012s | 0.586s | 1.225s | 0.020s | 0.720s | 0.026s | ~19x | ~51x |
| `miniz_full_validate` уровень 6 | 0.030s | 0.011s | 0.576s | 1.215s | 0.020s | 0.722s | 0.027s | ~19x | ~54x |
| `miniz_file_num_files` уровень 6 | 0.031s | 0.021s | 0.687s | 1.334s | 0.023s | 0.747s | 0.030s | ~22x | ~33x |
| `miniz_file_archive_size` уровень 6 | 0.034s | 0.021s | 0.707s | 1.187s | 0.023s | 0.803s | 0.034s | ~21x | ~33x |
| `miniz_file_extract_hash` уровень 6 | 0.032s | 0.021s | 0.689s | 1.348s | 0.025s | 0.868s | 0.032s | ~22x | ~33x |
| `miniz_file_in_place` уровень 6 | 0.031s | 0.021s | 0.703s | 1.272s | 0.022s | 0.728s | 0.032s | ~23x | ~34x |
| `lodepng_roundtrip` картинка 0 | 0.033s | 0.022s | 1.090s | 1.551s | 0.026s | 0.717s | 0.036s | ~33x | ~50x |
| `lodepng_encoded_size` картинка 0 | 0.034s | 0.020s | 0.980s | 1.457s | 0.024s | 0.710s | 0.034s | ~29x | ~49x |
| `lodepng_decode_hash` картинка 0 | 0.033s | 0.022s | 1.110s | 1.686s | 0.025s | 0.838s | 0.034s | ~33x | ~51x |
| `lodepng_input_hash` картинка 0 | 0.033s | 0.013s | 0.205s | 0.949s | 0.017s | 0.851s | 0.020s | ~6.2x | ~16x |
| `lodepng_png_hash` картинка 0 | 0.034s | 0.020s | 0.982s | 1.612s | 0.023s | 0.735s | 0.032s | ~29x | ~50x |
| `lodepng_encoded_size` картинка 1 | 0.034s | 0.023s | 1.398s | 2.010s | 0.029s | 0.730s | 0.036s | ~41x | ~60x |
| `lodepng_decode_hash` картинка 1 | 0.037s | 0.031s | 1.499s | 2.007s | 0.029s | 0.727s | 0.041s | ~40x | ~48x |
| `lodepng_input_hash` картинка 1 | 0.032s | 0.013s | 0.201s | 0.729s | 0.016s | 0.689s | 0.021s | ~6.2x | ~16x |
| `lodepng_png_hash` картинка 1 | 0.035s | 0.023s | 1.312s | 1.712s | 0.026s | 0.752s | 0.037s | ~38x | ~57x |
| `chipmunk_hash_scene` 60 шагов | 0.024s | 0.009s | 0.692s | 1.192s | 0.020s | 0.695s | 0.028s | ~29x | ~74x |
| `chipmunk_variant` 600 шагов | 0.025s | 0.080s | 6.316s | 6.640s | 0.096s | 0.807s | 0.124s | ~251x | ~79x |
| `chipmunk_probe_x` тело 0, 600 шагов | 0.025s | 0.065s | 5.215s | 5.149s | 0.080s | 0.799s | 0.102s | ~206x | ~80x |
| `chipmunk_probe_y` тело 1, 600 шагов | 0.024s | 0.065s | 5.157s | 5.355s | 0.080s | 0.809s | 0.103s | ~216x | ~80x |
| `chipmunk_probe_angle` тело 2, 600 шагов | 0.025s | 0.065s | 5.339s | 5.490s | 0.080s | 0.863s | 0.104s | ~212x | ~82x |
| `secret_expected_length` | 0.026s | 0.002s | 0.183s | 0.792s | 0.015s | 0.710s | 0.018s | ~6.9x | ~75x |
| `h264mp4_width` | 0.040s | 0.028s | 0.473s | 1.142s | 0.022s | 0.700s | 0.028s | ~12x | ~17x |
| `h264mp4_height` | 0.045s | 0.028s | 0.459s | 1.161s | 0.022s | 0.764s | 0.028s | ~10x | ~17x |
| `h264mp4_frame_count` 8 кадров | 0.039s | 0.038s | 1.178s | 1.649s | 0.033s | 0.756s | 0.040s | ~30x | ~31x |
| `h264mp4_first_frame` | 0.041s | 0.028s | 0.463s | 1.072s | 0.025s | 0.720s | 0.028s | ~11x | ~17x |
| `h264mp4_last_frame` 8 кадров | 0.043s | 0.040s | 1.201s | 1.658s | 0.034s | 0.701s | 0.040s | ~28x | ~30x |
| `plmpeg_width` | 0.027s | 0.047s | 0.461s | 1.035s | 0.024s | 0.699s | 0.029s | ~17x | ~9.9x |
| `plmpeg_height` | 0.026s | 0.049s | 0.483s | 1.030s | 0.024s | 0.722s | 0.029s | ~19x | ~9.8x |
| `plmpeg_frame_count` 8 кадров | 0.028s | 0.064s | 1.897s | 2.330s | 0.037s | 0.723s | 0.050s | ~69x | ~30x |
| `plmpeg_first_frame` | 0.027s | 0.049s | 0.530s | 1.103s | 0.024s | 0.698s | 0.029s | ~20x | ~11x |
| `plmpeg_last_frame` 8 кадров | 0.027s | 0.069s | 2.005s | 2.338s | 0.037s | 0.733s | 0.051s | ~74x | ~29x |
| `plmpeg_stream_width` | 0.020s | 0.049s | 0.523s | 1.081s | 0.024s | 0.723s | 0.029s | ~26x | ~11x |
| `plmpeg_stream_height` | 0.019s | 0.057s | 0.478s | 1.140s | 0.024s | 0.717s | 0.030s | ~25x | ~8.4x |
| `plmpeg_stream_frame_count` 8 кадров | 0.020s | 0.063s | 1.903s | 2.476s | 0.037s | 0.740s | 0.051s | ~93x | ~30x |
| `plmpeg_stream_first_frame` | 0.020s | 0.049s | 0.466s | 1.119s | 0.024s | 0.706s | 0.030s | ~23x | ~9.4x |
| `plmpeg_stream_last_frame` 8 кадров | 0.020s | 0.063s | 1.961s | 2.455s | 0.037s | 0.731s | 0.051s | ~98x | ~31x |
| `libjpeg_width` | 0.056s | 0.031s | 0.929s | 1.484s | 0.026s | 0.758s | 0.034s | ~17x | ~30x |
| `libjpeg_height` | 0.057s | 0.033s | 0.930s | 1.486s | 0.026s | 0.702s | 0.034s | ~16x | ~29x |
| `libjpeg_components` | 0.064s | 0.035s | 0.939s | 1.543s | 0.026s | 0.718s | 0.033s | ~15x | ~27x |
| `libjpeg_input_hash` | 0.056s | 0.024s | 0.191s | 0.921s | 0.019s | 0.684s | 0.022s | ~3.4x | ~8.0x |
| `libjpeg_rgb_size` | 0.059s | 0.032s | 0.904s | 1.452s | 0.026s | 0.753s | 0.034s | ~15x | ~28x |
| `mjpeg_width` | 0.056s | 0.026s | 0.395s | 0.876s | 0.020s | 0.709s | 0.026s | ~7.0x | ~15x |
| `mjpeg_height` | 0.057s | 0.027s | 0.410s | 0.926s | 0.021s | 0.688s | 0.026s | ~7.2x | ~15x |
| `mjpeg_components` | 0.059s | 0.027s | 0.394s | 0.929s | 0.021s | 0.770s | 0.027s | ~6.7x | ~15x |
| `mjpeg_frame_count` 12 кадров | 0.063s | 0.046s | 2.299s | 2.545s | 0.039s | 0.764s | 0.055s | ~37x | ~50x |
| `mjpeg_first_frame` | 0.067s | 0.030s | 0.432s | 1.045s | 0.021s | 0.715s | 0.027s | ~6.5x | ~15x |
| `mjpeg_last_frame` 12 кадров | 0.060s | 0.046s | 2.282s | 2.844s | 0.039s | 0.813s | 0.053s | ~38x | ~50x |
| `mjpeg_input_hash` | 0.057s | 0.026s | 0.238s | 0.970s | 0.019s | 0.734s | 0.023s | ~4.2x | ~9.0x |
| `binjgb_width` | 0.040s | 0.046s | 0.215s | 0.909s | 0.022s | 0.709s | 0.026s | ~5.4x | ~4.6x |
| `binjgb_height` | 0.040s | 0.047s | 0.221s | 0.873s | 0.029s | 0.706s | 0.026s | ~5.6x | ~4.7x |
| `binjgb_frame_count` 16 кадров | 0.058s | 0.243s | 18.142s | 16.399s | 0.173s | 0.998s | 0.278s | ~313x | ~75x |
| `binjgb_first_frame` | 0.041s | 0.056s | 1.288s | 1.901s | 0.033s | 0.744s | 0.044s | ~31x | ~23x |
| `binjgb_last_frame` 16 кадров | 0.051s | 0.192s | 17.312s | 16.641s | 0.173s | 1.009s | 0.275s | ~342x | ~90x |
| `builder_case_count` | 0.047s | 0.005s | 0.213s | 0.812s | 0.015s | 0.734s | 0.021s | ~4.5x | ~43x |
| `builder_c0_code_hash` вариант 0 | 0.060s | 0.007s | 0.299s | 0.905s | 0.018s | 0.691s | 0.021s | ~5.0x | ~46x |
| `builder_c1_code_hash` вариант 1 | 0.049s | 0.007s | 0.280s | 0.827s | 0.018s | 0.730s | 0.023s | ~5.7x | ~41x |
| `builder_c1_run_hash` вариант 1 | 0.061s | 0.007s | 0.311s | 0.928s | 0.020s | 0.711s | 0.022s | ~5.1x | ~46x |
| `builder_c2_code_hash` вариант 2 | 0.057s | 0.007s | 0.290s | 0.971s | 0.020s | 0.736s | 0.027s | ~5.1x | ~43x |
| `builder_c2_run_hash` вариант 2 | 0.049s | 0.007s | 0.292s | 0.917s | 0.018s | 0.718s | 0.024s | ~6.0x | ~44x |

Все результаты совпали с baseline (wasmtime 86/86, wasm3 C 86/86, wasm3das(inter) 86/86, wasm3das(aot) 86/86, wasm3das(aot_ctx) 86/86, wasm3das(jit) 86/86, wasm3das(exe) 86/86)

Ещё 12 строк(и) без документированного baseline остаются в таблице, их результат не проверяется.

## Итого (весь набор: основные + вариации)

| runtime | суммарное время | × к wasm3 C | старт (`fixtures/add`) | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasmtime | 3.393s | ~1.1x | 0.010s | 2.371s | ~0.8x |
| wasm3 C | 3.000s | ~1.0x | 0.001s | 2.886s | ~1.0x |
| wasm3das(inter) | 2m25.7s | ~49x | 0.195s | 2m06.6s | ~44x |
| wasm3das(aot) | 3m14.1s | ~65x | 0.778s | 1m57.8s | ~41x |
| wasm3das(aot_ctx) | 2.979s | ~1.0x | 0.014s | 1.585s | ~0.5x |
| wasm3das(jit) | 1m14.1s | ~25x | 0.691s | 6.423s | ~2.2x |
| wasm3das(exe) | 4.014s | ~1.3x | 0.018s | 2.296s | ~0.8x |

Старт это минимальное полное время среди строк без исполнения (`add`, `hash_f32`, `hash_f64`), «без старта» это сумма минус старт на каждую засчитанную строку: оценка рядом с честным полным временем, не вместо него.

## Прогон

- Date (UTC): 2026-09-22T20:07:37Z
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

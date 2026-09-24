# Spider manual fixtures: parity and timing

## Основные

По одной продакшен-конфигурации на модуль: самый тяжёлый реальный экспорт (декодер, полный цикл, длинная симуляция). Остальные экспорты и вариации аргументов — справочной таблицей ниже.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `add` 1 2 | 0.061s | 0.002s | 0.700s | 0.619s | 0.014s | 1.402s | 0.018s | ~12x | ~290x |
| `hash_loop` seed 123456789, 200000 итераций | 0.014s | 0.004s | 0.466s | 0.779s | 0.028s | 0.486s | 0.025s | ~34x | ~122x |
| `hash_f32` 2048 элементов | 0.011s | 0.001s | 0.163s | 0.580s | 0.014s | 0.482s | 0.018s | ~14x | ~126x |
| `hash_f64` 2048 элементов | 0.010s | 0.001s | 0.167s | 0.557s | 0.015s | 0.475s | 0.017s | ~16x | ~135x |
| `hash_i64_mix` 512 элементов | 0.013s | 0.001s | 0.157s | 0.568s | 0.014s | 0.474s | 0.018s | ~13x | ~118x |
| `hash_i64_div` 512 элементов | 0.011s | 0.001s | 0.156s | 0.618s | 0.015s | 0.479s | 0.017s | ~14x | ~108x |
| `tinyexpr_hash` 256 выражений | 0.020s | 0.003s | 0.218s | 0.621s | 0.016s | 0.490s | 0.019s | ~11x | ~84x |
| `miniz_roundtrip_hash` уровень 6 | 0.035s | 0.005s | 0.364s | 0.684s | 0.022s | 0.505s | 0.023s | ~10x | ~80x |
| `miniz_full_hash` уровень 6 | 0.057s | 0.011s | 0.436s | 0.754s | 0.025s | 0.485s | 0.025s | ~7.7x | ~41x |
| `miniz_file_hash` уровень 6 | 0.030s | 0.020s | 0.521s | 0.780s | 0.029s | 0.506s | 0.029s | ~17x | ~27x |
| `lodepng_roundtrip` картинка 1 | 0.033s | 0.025s | 1.040s | 1.155s | 0.051s | 0.497s | 0.044s | ~32x | ~41x |
| `chipmunk_hash_scene` 600 шагов | 0.024s | 0.062s | 3.443s | 2.840s | 0.163s | 0.569s | 0.113s | ~143x | ~56x |
| `secret_expected_crc32` | 0.023s | 0.003s | 0.158s | 0.605s | 0.015s | 0.486s | 0.017s | ~6.7x | ~55x |
| `profile_memory_walk` 400 итераций | 0.023s | 0.007s | 0.557s | 0.884s | 0.032s | 0.519s | 0.028s | ~24x | ~83x |
| `profile_math_shim` 400 итераций | 0.023s | 0.005s | 0.203s | 0.635s | 0.017s | 0.480s | 0.020s | ~8.9x | ~44x |
| `profile_branch_state` 400 итераций | 0.022s | 0.004s | 0.215s | 0.627s | 0.017s | 0.495s | 0.019s | ~9.6x | ~51x |
| `profile_space_freefall` 120 шагов | 0.022s | 0.006s | 0.287s | 0.640s | 0.019s | 0.495s | 0.023s | ~13x | ~49x |
| `profile_space_collision` 120 шагов | 0.022s | 0.014s | 0.798s | 1.003s | 0.042s | 0.507s | 0.037s | ~36x | ~55x |
| `profile_space_full` 120 шагов | 0.023s | 0.015s | 0.792s | 0.968s | 0.042s | 0.508s | 0.038s | ~35x | ~54x |
| `h264mp4_decode_hash` 8 кадров | 0.042s | 0.038s | 0.847s | 1.018s | 0.048s | 0.503s | 0.040s | ~20x | ~22x |
| `plmpeg_decode_hash` 8 кадров | 0.030s | 0.060s | 1.278s | 1.319s | 0.070s | 0.513s | 0.053s | ~43x | ~21x |
| `plmpeg_stream_decode_hash` 8 кадров | 0.020s | 0.062s | 1.254s | 1.286s | 0.068s | 0.535s | 0.052s | ~63x | ~20x |
| `libjpeg_decode_hash` | 0.058s | 0.032s | 0.698s | 0.902s | 0.043s | 0.494s | 0.037s | ~12x | ~22x |
| `mjpeg_decode_hash` 12 кадров | 0.058s | 0.045s | 1.486s | 1.476s | 0.074s | 0.524s | 0.058s | ~26x | ~33x |
| `binjgb_decode_hash` 16 кадров | 0.049s | 0.187s | 11.312s | 8.375s | 0.480s | 0.846s | 0.302s | ~229x | ~60x |
| `builder_c0_run_hash` вариант 0 | 0.044s | 0.006s | 0.238s | 0.592s | 0.018s | 0.479s | 0.023s | ~5.4x | ~37x |

| runtime | суммарное время (основные) | × к wasm3 C | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: |
| wasmtime | 0.778s | ~1.3x | 0.509s | ~0.9x |
| wasm3 C | 0.620s | ~1.0x | 0.588s | ~1.0x |
| wasm3das(inter) | 27.954s | ~45x | 23.715s | ~40x |
| wasm3das(aot) | 30.884s | ~50x | 16.411s | ~28x |
| wasm3das(aot_ctx) | 1.390s | ~2.2x | 1.018s | ~1.7x |
| wasm3das(jit) | 14.233s | ~23x | 1.885s | ~3.2x |
| wasm3das(exe) | 1.111s | ~1.8x | 0.660s | ~1.1x |

## Вариации аргументов и остальные экспорты

Справочные строки: остальные экспорты модулей, отладочные пробы и остальные конфигурации аргументов. Методика и колонки те же.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hash_loop` seed 1, 65536 итераций | 0.011s | 0.002s | 0.250s | 0.665s | 0.019s | 0.476s | 0.020s | ~23x | ~111x |
| `probe_div_s64` | 0.011s | 0.001s | 0.155s | 0.562s | 0.014s | 0.473s | 0.017s | ~14x | ~105x |
| `probe_rem_s64` | 0.012s | 0.001s | 0.157s | 0.584s | 0.014s | 0.479s | 0.016s | ~13x | ~135x |
| `probe_div_u64` | 0.012s | 0.001s | 0.151s | 0.578s | 0.013s | 0.471s | 0.017s | ~13x | ~130x |
| `probe_rem_u64` | 0.011s | 0.001s | 0.151s | 0.566s | 0.014s | 0.487s | 0.016s | ~13x | ~130x |
| `tinyexpr_error_code` | 0.015s | 0.001s | 0.157s | 0.599s | 0.014s | 0.489s | 0.017s | ~10x | ~109x |
| `miniz_probe_compressed_size` уровень 6 | 0.026s | 0.004s | 0.312s | 0.690s | 0.020s | 0.485s | 0.021s | ~12x | ~81x |
| `miniz_probe_crc32` | 0.024s | 0.002s | 0.178s | 0.589s | 0.015s | 0.475s | 0.018s | ~7.3x | ~82x |
| `miniz_probe_adler32` | 0.025s | 0.002s | 0.177s | 0.573s | 0.015s | 0.482s | 0.018s | ~7.1x | ~88x |
| `miniz_probe_fold_hash` | 0.026s | 0.002s | 0.169s | 0.574s | 0.015s | 0.475s | 0.018s | ~6.5x | ~87x |
| `miniz_full_num_files` уровень 6 | 0.029s | 0.010s | 0.441s | 0.735s | 0.025s | 0.488s | 0.026s | ~15x | ~43x |
| `miniz_full_archive_size` уровень 6 | 0.028s | 0.010s | 0.436s | 0.716s | 0.025s | 0.492s | 0.025s | ~16x | ~42x |
| `miniz_full_locate_mix` уровень 6 | 0.030s | 0.010s | 0.435s | 0.710s | 0.025s | 0.492s | 0.025s | ~15x | ~42x |
| `miniz_full_extract_hash` уровень 6 | 0.029s | 0.010s | 0.442s | 0.720s | 0.025s | 0.485s | 0.025s | ~15x | ~43x |
| `miniz_full_validate` уровень 6 | 0.028s | 0.011s | 0.439s | 0.716s | 0.026s | 0.491s | 0.025s | ~15x | ~42x |
| `miniz_file_num_files` уровень 6 | 0.030s | 0.019s | 0.527s | 0.772s | 0.029s | 0.491s | 0.029s | ~17x | ~27x |
| `miniz_file_archive_size` уровень 6 | 0.029s | 0.020s | 0.520s | 0.770s | 0.028s | 0.492s | 0.029s | ~18x | ~27x |
| `miniz_file_extract_hash` уровень 6 | 0.031s | 0.019s | 0.517s | 0.765s | 0.028s | 0.499s | 0.028s | ~16x | ~27x |
| `miniz_file_in_place` уровень 6 | 0.030s | 0.019s | 0.526s | 0.781s | 0.029s | 0.487s | 0.029s | ~17x | ~27x |
| `lodepng_roundtrip` картинка 0 | 0.035s | 0.021s | 0.777s | 0.937s | 0.039s | 0.492s | 0.035s | ~22x | ~37x |
| `lodepng_encoded_size` картинка 0 | 0.032s | 0.019s | 0.688s | 0.884s | 0.036s | 0.496s | 0.032s | ~22x | ~37x |
| `lodepng_decode_hash` картинка 0 | 0.031s | 0.020s | 0.772s | 0.979s | 0.039s | 0.504s | 0.036s | ~25x | ~38x |
| `lodepng_input_hash` картинка 0 | 0.033s | 0.012s | 0.168s | 0.595s | 0.017s | 0.474s | 0.021s | ~5.2x | ~14x |
| `lodepng_png_hash` картинка 0 | 0.034s | 0.019s | 0.696s | 0.906s | 0.036s | 0.494s | 0.033s | ~20x | ~36x |
| `lodepng_encoded_size` картинка 1 | 0.033s | 0.022s | 0.914s | 1.068s | 0.047s | 0.503s | 0.038s | ~28x | ~42x |
| `lodepng_decode_hash` картинка 1 | 0.034s | 0.024s | 1.051s | 1.131s | 0.052s | 0.504s | 0.042s | ~31x | ~44x |
| `lodepng_input_hash` картинка 1 | 0.032s | 0.012s | 0.166s | 0.567s | 0.017s | 0.483s | 0.019s | ~5.2x | ~14x |
| `lodepng_png_hash` картинка 1 | 0.034s | 0.022s | 0.913s | 1.071s | 0.046s | 0.495s | 0.038s | ~27x | ~41x |
| `chipmunk_hash_scene` 60 шагов | 0.024s | 0.009s | 0.495s | 0.792s | 0.029s | 0.488s | 0.028s | ~21x | ~55x |
| `chipmunk_variant` 600 шагов | 0.026s | 0.080s | 4.238s | 3.429s | 0.202s | 0.610s | 0.137s | ~163x | ~53x |
| `chipmunk_probe_x` тело 0, 600 шагов | 0.024s | 0.063s | 3.354s | 2.817s | 0.161s | 0.596s | 0.113s | ~140x | ~53x |
| `chipmunk_probe_y` тело 1, 600 шагов | 0.024s | 0.064s | 3.380s | 2.783s | 0.160s | 0.579s | 0.112s | ~139x | ~53x |
| `chipmunk_probe_angle` тело 2, 600 шагов | 0.024s | 0.064s | 3.378s | 2.811s | 0.159s | 0.578s | 0.114s | ~139x | ~53x |
| `secret_expected_length` | 0.023s | 0.003s | 0.158s | 0.602s | 0.015s | 0.485s | 0.018s | ~6.8x | ~62x |
| `h264mp4_width` | 0.039s | 0.027s | 0.362s | 0.662s | 0.026s | 0.490s | 0.027s | ~9.2x | ~14x |
| `h264mp4_height` | 0.040s | 0.027s | 0.359s | 0.686s | 0.027s | 0.494s | 0.027s | ~8.9x | ~13x |
| `h264mp4_frame_count` 8 кадров | 0.039s | 0.037s | 0.845s | 0.986s | 0.048s | 0.500s | 0.042s | ~22x | ~23x |
| `h264mp4_first_frame` | 0.037s | 0.027s | 0.360s | 0.660s | 0.025s | 0.490s | 0.027s | ~9.7x | ~14x |
| `h264mp4_last_frame` 8 кадров | 0.038s | 0.037s | 0.864s | 0.984s | 0.048s | 0.510s | 0.040s | ~23x | ~23x |
| `plmpeg_width` | 0.029s | 0.045s | 0.339s | 0.747s | 0.029s | 0.490s | 0.030s | ~12x | ~7.5x |
| `plmpeg_height` | 0.027s | 0.046s | 0.344s | 0.705s | 0.032s | 0.516s | 0.029s | ~13x | ~7.6x |
| `plmpeg_frame_count` 8 кадров | 0.028s | 0.060s | 1.260s | 1.380s | 0.068s | 0.514s | 0.052s | ~45x | ~21x |
| `plmpeg_first_frame` | 0.027s | 0.045s | 0.347s | 0.698s | 0.029s | 0.487s | 0.031s | ~13x | ~7.6x |
| `plmpeg_last_frame` 8 кадров | 0.028s | 0.060s | 1.248s | 1.335s | 0.068s | 0.510s | 0.054s | ~45x | ~21x |
| `plmpeg_stream_width` | 0.020s | 0.046s | 0.343s | 0.683s | 0.028s | 0.505s | 0.030s | ~18x | ~7.5x |
| `plmpeg_stream_height` | 0.018s | 0.045s | 0.344s | 0.719s | 0.029s | 0.487s | 0.033s | ~19x | ~7.6x |
| `plmpeg_stream_frame_count` 8 кадров | 0.019s | 0.061s | 1.260s | 1.336s | 0.071s | 0.513s | 0.054s | ~66x | ~21x |
| `plmpeg_stream_first_frame` | 0.019s | 0.045s | 0.345s | 0.688s | 0.029s | 0.498s | 0.029s | ~18x | ~7.6x |
| `plmpeg_stream_last_frame` 8 кадров | 0.019s | 0.060s | 1.256s | 1.303s | 0.069s | 0.513s | 0.052s | ~65x | ~21x |
| `libjpeg_width` | 0.057s | 0.031s | 0.636s | 0.872s | 0.038s | 0.493s | 0.036s | ~11x | ~20x |
| `libjpeg_height` | 0.053s | 0.031s | 0.645s | 0.906s | 0.037s | 0.504s | 0.035s | ~12x | ~21x |
| `libjpeg_components` | 0.053s | 0.031s | 0.624s | 0.897s | 0.037s | 0.495s | 0.036s | ~12x | ~20x |
| `libjpeg_input_hash` | 0.055s | 0.023s | 0.161s | 0.594s | 0.020s | 0.483s | 0.023s | ~2.9x | ~7.1x |
| `libjpeg_rgb_size` | 0.056s | 0.031s | 0.630s | 0.864s | 0.038s | 0.510s | 0.034s | ~11x | ~20x |
| `mjpeg_width` | 0.053s | 0.025s | 0.312s | 0.675s | 0.025s | 0.502s | 0.026s | ~5.9x | ~12x |
| `mjpeg_height` | 0.053s | 0.026s | 0.310s | 0.645s | 0.023s | 0.483s | 0.025s | ~5.9x | ~12x |
| `mjpeg_components` | 0.057s | 0.026s | 0.318s | 0.677s | 0.025s | 0.485s | 0.027s | ~5.6x | ~12x |
| `mjpeg_frame_count` 12 кадров | 0.056s | 0.045s | 1.487s | 1.430s | 0.076s | 0.515s | 0.061s | ~27x | ~33x |
| `mjpeg_first_frame` | 0.054s | 0.025s | 0.313s | 0.672s | 0.023s | 0.486s | 0.027s | ~5.8x | ~12x |
| `mjpeg_last_frame` 12 кадров | 0.054s | 0.045s | 1.483s | 1.413s | 0.073s | 0.532s | 0.060s | ~27x | ~33x |
| `mjpeg_input_hash` | 0.057s | 0.023s | 0.176s | 0.612s | 0.020s | 0.483s | 0.022s | ~3.1x | ~7.6x |
| `binjgb_width` | 0.039s | 0.043s | 0.167s | 0.582s | 0.025s | 0.486s | 0.025s | ~4.3x | ~3.9x |
| `binjgb_height` | 0.038s | 0.043s | 0.163s | 0.588s | 0.021s | 0.488s | 0.027s | ~4.3x | ~3.8x |
| `binjgb_frame_count` 16 кадров | 0.052s | 0.187s | 11.127s | 8.226s | 0.476s | 0.796s | 0.302s | ~215x | ~59x |
| `binjgb_first_frame` | 0.041s | 0.053s | 0.881s | 1.051s | 0.049s | 0.518s | 0.044s | ~22x | ~17x |
| `binjgb_last_frame` 16 кадров | 0.048s | 0.185s | 11.303s | 8.247s | 0.477s | 0.829s | 0.303s | ~236x | ~61x |
| `builder_case_count` | 0.046s | 0.005s | 0.157s | 0.566s | 0.015s | 0.475s | 0.018s | ~3.4x | ~33x |
| `builder_c0_code_hash` вариант 0 | 0.043s | 0.007s | 0.243s | 0.587s | 0.017s | 0.487s | 0.022s | ~5.6x | ~36x |
| `builder_c1_code_hash` вариант 1 | 0.046s | 0.006s | 0.256s | 0.607s | 0.018s | 0.486s | 0.022s | ~5.5x | ~42x |
| `builder_c1_run_hash` вариант 1 | 0.044s | 0.006s | 0.251s | 0.607s | 0.018s | 0.489s | 0.022s | ~5.7x | ~39x |
| `builder_c2_code_hash` вариант 2 | 0.043s | 0.006s | 0.258s | 0.576s | 0.018s | 0.483s | 0.022s | ~6.0x | ~41x |
| `builder_c2_run_hash` вариант 2 | 0.044s | 0.007s | 0.258s | 0.626s | 0.018s | 0.496s | 0.022s | ~5.9x | ~39x |

Все результаты совпали с baseline (wasmtime 86/86, wasm3 C 86/86, wasm3das(inter) 86/86, wasm3das(aot) 86/86, wasm3das(aot_ctx) 86/86, wasm3das(jit) 86/86, wasm3das(exe) 86/86)

Ещё 12 строк(и) без документированного baseline остаются в таблице, их результат не проверяется.

## Итого (весь набор: основные + вариации)

| runtime | суммарное время | × к wasm3 C | старт (`fixtures/add`) | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasmtime | 3.226s | ~1.2x | 0.010s | 2.213s | ~0.8x |
| wasm3 C | 2.799s | ~1.0x | 0.001s | 2.678s | ~1.0x |
| wasm3das(inter) | 1m37.3s | ~35x | 0.163s | 1m21.3s | ~30x |
| wasm3das(aot) | 1m51.0s | ~40x | 0.557s | 56.460s | ~21x |
| wasm3das(aot_ctx) | 5.054s | ~1.8x | 0.014s | 3.649s | ~1.4x |
| wasm3das(jit) | 50.744s | ~18x | 0.475s | 4.205s | ~1.6x |
| wasm3das(exe) | 4.147s | ~1.5x | 0.017s | 2.447s | ~0.9x |

Старт это минимальное полное время среди строк без исполнения (`add`, `hash_f32`, `hash_f64`), «без старта» это сумма минус старт на каждую засчитанную строку: оценка рядом с честным полным временем, не вместо него.

## Прогон

- Date (UTC): 2026-09-22T23:39:43Z
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

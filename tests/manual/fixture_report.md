# Spider manual fixtures: parity and timing

## Основные

По одной продакшен-конфигурации на модуль: самый тяжёлый реальный экспорт (декодер, полный цикл, длинная симуляция). Остальные экспорты и вариации аргументов — справочной таблицей ниже.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `add` 1 2 | 0.011s | 0.002s | 0.159s | 0.770s | 0.027s | 0.422s | 0.023s | ~14x | ~90x |
| `hash_loop` seed 123456789, 200000 итераций | 0.011s | 0.004s | 0.452s | 0.930s | 0.043s | 0.464s | 0.050s | ~42x | ~111x |
| `hash_f32` 2048 элементов | 0.010s | 0.001s | 0.157s | 0.834s | 0.028s | 0.416s | 0.023s | ~15x | ~112x |
| `hash_f64` 2048 элементов | 0.011s | 0.001s | 0.158s | 0.808s | 0.029s | 0.425s | 0.023s | ~14x | ~110x |
| `hash_i64_mix` 512 элементов | 0.013s | 0.001s | 0.175s | 0.805s | 0.027s | 0.417s | 0.024s | ~14x | ~117x |
| `hash_i64_div` 512 элементов | 0.013s | 0.001s | 0.161s | 0.731s | 0.032s | 0.470s | 0.025s | ~13x | ~109x |
| `tinyexpr_hash` 256 выражений | 0.017s | 0.002s | 0.244s | 0.911s | 0.033s | 0.478s | 0.035s | ~15x | ~98x |
| `miniz_roundtrip_hash` уровень 6 | 0.026s | 0.005s | 0.460s | 1.002s | 0.043s | 0.451s | 0.042s | ~18x | ~97x |
| `miniz_full_hash` уровень 6 | 0.035s | 0.012s | 0.460s | 1.129s | 0.048s | 0.471s | 0.047s | ~13x | ~40x |
| `miniz_file_hash` уровень 6 | 0.036s | 0.022s | 0.529s | 1.015s | 0.053s | 0.481s | 0.054s | ~15x | ~24x |
| `lodepng_roundtrip` картинка 1 | 0.035s | 0.026s | 1.017s | 1.337s | 0.077s | 0.512s | 0.099s | ~29x | ~40x |
| `chipmunk_hash_scene` 600 шагов | 0.025s | 0.064s | 3.327s | 3.061s | 0.226s | 0.739s | 0.339s | ~135x | ~52x |
| `secret_expected_crc32` | 0.029s | 0.003s | 0.157s | 0.843s | 0.029s | 0.421s | 0.023s | ~5.4x | ~58x |
| `profile_memory_walk` 400 итераций | 0.025s | 0.007s | 0.567s | 1.153s | 0.047s | 0.477s | 0.059s | ~23x | ~82x |
| `profile_math_shim` 400 итераций | 0.023s | 0.005s | 0.207s | 0.878s | 0.032s | 0.453s | 0.027s | ~8.9x | ~45x |
| `profile_branch_state` 400 итераций | 0.022s | 0.005s | 0.219s | 0.889s | 0.032s | 0.449s | 0.030s | ~9.8x | ~46x |
| `profile_space_freefall` 120 шагов | 0.023s | 0.006s | 0.318s | 0.871s | 0.037s | 0.493s | 0.034s | ~14x | ~54x |
| `profile_space_collision` 120 шагов | 0.023s | 0.015s | 0.814s | 1.211s | 0.064s | 0.488s | 0.092s | ~36x | ~53x |
| `profile_space_full` 120 шагов | 0.025s | 0.015s | 0.859s | 1.270s | 0.065s | 0.505s | 0.084s | ~35x | ~57x |
| `h264mp4_decode_hash` 8 кадров | 0.049s | 0.039s | 0.851s | 1.248s | 0.071s | 0.505s | 0.085s | ~17x | ~22x |
| `plmpeg_decode_hash` 8 кадров | 0.029s | 0.063s | 1.329s | 1.587s | 0.091s | 0.548s | 0.128s | ~45x | ~21x |
| `plmpeg_stream_decode_hash` 8 кадров | 0.023s | 0.070s | 1.287s | 1.547s | 0.101s | 0.517s | 0.125s | ~57x | ~18x |
| `libjpeg_decode_hash` | 0.060s | 0.033s | 0.692s | 1.213s | 0.060s | 0.479s | 0.073s | ~11x | ~21x |
| `mjpeg_decode_hash` 12 кадров | 0.063s | 0.049s | 1.571s | 1.719s | 0.099s | 0.559s | 0.140s | ~25x | ~32x |
| `binjgb_decode_hash` 16 кадров | 0.059s | 0.192s | 11.328s | 8.324s | 0.578s | 1.381s | 0.922s | ~193x | ~59x |
| `builder_c0_run_hash` вариант 0 | 0.048s | 0.007s | 0.241s | 0.790s | 0.041s | 0.437s | 0.028s | ~5.0x | ~37x |

| runtime | суммарное время (основные) | × к wasm3 C | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: |
| wasmtime | 0.743s | ~1.1x | 0.473s | ~0.8x |
| wasm3 C | 0.650s | ~1.0x | 0.613s | ~1.0x |
| wasm3das(inter) | 27.737s | ~43x | 23.665s | ~39x |
| wasm3das(aot) | 36.876s | ~57x | 16.855s | ~27x |
| wasm3das(aot_ctx) | 2.012s | ~3.1x | 1.318s | ~2.1x |
| wasm3das(jit) | 13.459s | ~21x | 2.646s | ~4.3x |
| wasm3das(exe) | 2.632s | ~4.1x | 2.047s | ~3.3x |

## Вариации аргументов и остальные экспорты

Справочные строки: остальные экспорты модулей, отладочные пробы и остальные конфигурации аргументов. Методика и колонки те же.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hash_loop` seed 1, 65536 итераций | 0.011s | 0.002s | 0.250s | 0.772s | 0.033s | 0.451s | 0.031s | ~23x | ~126x |
| `probe_div_s64` | 0.011s | 0.002s | 0.151s | 0.772s | 0.032s | 0.454s | 0.024s | ~13x | ~97x |
| `probe_rem_s64` | 0.012s | 0.001s | 0.157s | 0.811s | 0.031s | 0.439s | 0.024s | ~13x | ~120x |
| `probe_div_u64` | 0.013s | 0.002s | 0.161s | 0.794s | 0.031s | 0.473s | 0.024s | ~12x | ~104x |
| `probe_rem_u64` | 0.012s | 0.001s | 0.167s | 0.992s | 0.030s | 0.469s | 0.024s | ~14x | ~118x |
| `tinyexpr_error_code` | 0.017s | 0.002s | 0.170s | 0.913s | 0.029s | 0.525s | 0.023s | ~9.8x | ~105x |
| `miniz_probe_compressed_size` уровень 6 | 0.025s | 0.004s | 0.309s | 0.879s | 0.036s | 0.436s | 0.037s | ~12x | ~76x |
| `miniz_probe_crc32` | 0.026s | 0.003s | 0.180s | 0.827s | 0.034s | 0.470s | 0.027s | ~6.8x | ~61x |
| `miniz_probe_adler32` | 0.029s | 0.002s | 0.202s | 0.935s | 0.030s | 0.467s | 0.029s | ~7.0x | ~86x |
| `miniz_probe_fold_hash` | 0.027s | 0.002s | 0.222s | 0.997s | 0.035s | 0.453s | 0.028s | ~8.2x | ~101x |
| `miniz_full_num_files` уровень 6 | 0.036s | 0.014s | 0.535s | 1.153s | 0.049s | 0.503s | 0.047s | ~15x | ~38x |
| `miniz_full_archive_size` уровень 6 | 0.031s | 0.012s | 0.456s | 1.041s | 0.046s | 0.473s | 0.049s | ~15x | ~40x |
| `miniz_full_locate_mix` уровень 6 | 0.030s | 0.011s | 0.450s | 1.130s | 0.046s | 0.507s | 0.047s | ~15x | ~41x |
| `miniz_full_extract_hash` уровень 6 | 0.033s | 0.011s | 0.454s | 1.030s | 0.044s | 0.461s | 0.046s | ~14x | ~41x |
| `miniz_full_validate` уровень 6 | 0.029s | 0.011s | 0.432s | 1.103s | 0.050s | 0.507s | 0.048s | ~15x | ~40x |
| `miniz_file_num_files` уровень 6 | 0.033s | 0.020s | 0.537s | 0.980s | 0.051s | 0.522s | 0.058s | ~16x | ~26x |
| `miniz_file_archive_size` уровень 6 | 0.035s | 0.023s | 0.530s | 1.211s | 0.051s | 0.473s | 0.055s | ~15x | ~24x |
| `miniz_file_extract_hash` уровень 6 | 0.035s | 0.021s | 0.535s | 1.182s | 0.052s | 0.464s | 0.056s | ~15x | ~25x |
| `miniz_file_in_place` уровень 6 | 0.033s | 0.021s | 0.515s | 1.178s | 0.048s | 0.450s | 0.053s | ~16x | ~25x |
| `lodepng_roundtrip` картинка 0 | 0.035s | 0.021s | 0.758s | 1.085s | 0.060s | 0.462s | 0.074s | ~22x | ~36x |
| `lodepng_encoded_size` картинка 0 | 0.033s | 0.019s | 0.698s | 1.103s | 0.054s | 0.457s | 0.067s | ~21x | ~36x |
| `lodepng_decode_hash` картинка 0 | 0.033s | 0.021s | 0.746s | 1.171s | 0.061s | 0.469s | 0.073s | ~23x | ~35x |
| `lodepng_input_hash` картинка 0 | 0.031s | 0.013s | 0.163s | 0.716s | 0.032s | 0.431s | 0.026s | ~5.3x | ~13x |
| `lodepng_png_hash` картинка 0 | 0.034s | 0.020s | 0.655s | 1.096s | 0.059s | 0.465s | 0.068s | ~19x | ~33x |
| `lodepng_encoded_size` картинка 1 | 0.034s | 0.025s | 0.887s | 1.193s | 0.067s | 0.479s | 0.085s | ~26x | ~36x |
| `lodepng_decode_hash` картинка 1 | 0.034s | 0.026s | 1.007s | 1.311s | 0.071s | 0.481s | 0.096s | ~29x | ~38x |
| `lodepng_input_hash` картинка 1 | 0.032s | 0.012s | 0.168s | 0.720s | 0.030s | 0.418s | 0.026s | ~5.2x | ~14x |
| `lodepng_png_hash` картинка 1 | 0.034s | 0.023s | 0.879s | 1.223s | 0.066s | 0.473s | 0.087s | ~26x | ~38x |
| `chipmunk_hash_scene` 60 шагов | 0.023s | 0.010s | 0.533s | 1.012s | 0.047s | 0.449s | 0.052s | ~23x | ~54x |
| `chipmunk_variant` 600 шагов | 0.027s | 0.082s | 4.408s | 3.668s | 0.255s | 0.807s | 0.434s | ~165x | ~54x |
| `chipmunk_probe_x` тело 0, 600 шагов | 0.025s | 0.064s | 3.493s | 3.070s | 0.213s | 0.731s | 0.335s | ~138x | ~55x |
| `chipmunk_probe_y` тело 1, 600 шагов | 0.025s | 0.064s | 3.446s | 3.055s | 0.210s | 0.733s | 0.333s | ~139x | ~54x |
| `chipmunk_probe_angle` тело 2, 600 шагов | 0.025s | 0.065s | 3.489s | 3.135s | 0.198s | 0.741s | 0.347s | ~142x | ~54x |
| `secret_expected_length` | 0.025s | 0.003s | 0.156s | 0.833s | 0.029s | 0.441s | 0.024s | ~6.2x | ~60x |
| `h264mp4_width` | 0.047s | 0.028s | 0.387s | 0.939s | 0.050s | 0.469s | 0.041s | ~8.3x | ~14x |
| `h264mp4_height` | 0.042s | 0.027s | 0.358s | 0.948s | 0.048s | 0.437s | 0.041s | ~8.5x | ~13x |
| `h264mp4_frame_count` 8 кадров | 0.048s | 0.039s | 0.908s | 1.268s | 0.072s | 0.498s | 0.095s | ~19x | ~24x |
| `h264mp4_first_frame` | 0.044s | 0.029s | 0.393s | 1.080s | 0.048s | 0.465s | 0.042s | ~8.8x | ~13x |
| `h264mp4_last_frame` 8 кадров | 0.044s | 0.040s | 0.930s | 1.283s | 0.072s | 0.493s | 0.086s | ~21x | ~23x |
| `plmpeg_width` | 0.028s | 0.047s | 0.360s | 0.963s | 0.046s | 0.496s | 0.051s | ~13x | ~7.6x |
| `plmpeg_height` | 0.027s | 0.048s | 0.347s | 1.002s | 0.045s | 0.446s | 0.055s | ~13x | ~7.3x |
| `plmpeg_frame_count` 8 кадров | 0.029s | 0.062s | 1.263s | 1.596s | 0.092s | 0.556s | 0.127s | ~44x | ~20x |
| `plmpeg_first_frame` | 0.028s | 0.048s | 0.381s | 0.949s | 0.044s | 0.456s | 0.045s | ~14x | ~8.0x |
| `plmpeg_last_frame` 8 кадров | 0.028s | 0.062s | 1.303s | 1.644s | 0.087s | 0.540s | 0.126s | ~47x | ~21x |
| `plmpeg_stream_width` | 0.019s | 0.047s | 0.359s | 0.948s | 0.049s | 0.448s | 0.046s | ~19x | ~7.6x |
| `plmpeg_stream_height` | 0.018s | 0.052s | 0.350s | 0.942s | 0.045s | 0.438s | 0.051s | ~19x | ~6.7x |
| `plmpeg_stream_frame_count` 8 кадров | 0.021s | 0.062s | 1.247s | 1.563s | 0.101s | 0.549s | 0.133s | ~59x | ~20x |
| `plmpeg_stream_first_frame` | 0.020s | 0.047s | 0.344s | 1.017s | 0.045s | 0.458s | 0.044s | ~17x | ~7.3x |
| `plmpeg_stream_last_frame` 8 кадров | 0.020s | 0.069s | 1.274s | 1.471s | 0.086s | 0.507s | 0.133s | ~64x | ~18x |
| `libjpeg_width` | 0.059s | 0.032s | 0.669s | 1.339s | 0.056s | 0.482s | 0.070s | ~11x | ~21x |
| `libjpeg_height` | 0.072s | 0.034s | 0.668s | 1.163s | 0.056s | 0.469s | 0.067s | ~9.3x | ~20x |
| `libjpeg_components` | 0.062s | 0.032s | 0.634s | 1.064s | 0.058s | 0.479s | 0.071s | ~10x | ~20x |
| `libjpeg_input_hash` | 0.058s | 0.024s | 0.182s | 0.850s | 0.033s | 0.432s | 0.029s | ~3.2x | ~7.7x |
| `libjpeg_rgb_size` | 0.059s | 0.033s | 0.654s | 1.106s | 0.057s | 0.469s | 0.068s | ~11x | ~20x |
| `mjpeg_width` | 0.059s | 0.026s | 0.343s | 0.877s | 0.044s | 0.462s | 0.039s | ~5.8x | ~13x |
| `mjpeg_height` | 0.064s | 0.026s | 0.344s | 0.868s | 0.041s | 0.437s | 0.041s | ~5.4x | ~13x |
| `mjpeg_components` | 0.063s | 0.027s | 0.309s | 0.850s | 0.041s | 0.488s | 0.037s | ~4.9x | ~11x |
| `mjpeg_frame_count` 12 кадров | 0.060s | 0.046s | 1.512s | 1.677s | 0.099s | 0.549s | 0.144s | ~25x | ~33x |
| `mjpeg_first_frame` | 0.060s | 0.026s | 0.331s | 0.809s | 0.041s | 0.465s | 0.037s | ~5.5x | ~13x |
| `mjpeg_last_frame` 12 кадров | 0.059s | 0.049s | 1.486s | 1.632s | 0.097s | 0.564s | 0.155s | ~25x | ~30x |
| `mjpeg_input_hash` | 0.064s | 0.024s | 0.211s | 0.828s | 0.033s | 0.441s | 0.029s | ~3.3x | ~8.8x |
| `binjgb_width` | 0.042s | 0.046s | 0.176s | 0.909s | 0.035s | 0.430s | 0.030s | ~4.2x | ~3.8x |
| `binjgb_height` | 0.038s | 0.044s | 0.187s | 0.906s | 0.042s | 0.447s | 0.031s | ~4.9x | ~4.2x |
| `binjgb_frame_count` 16 кадров | 0.049s | 0.188s | 11.060s | 8.114s | 0.537s | 1.271s | 0.942s | ~227x | ~59x |
| `binjgb_first_frame` | 0.042s | 0.053s | 0.870s | 1.188s | 0.069s | 0.496s | 0.090s | ~21x | ~17x |
| `binjgb_last_frame` 16 кадров | 0.057s | 0.187s | 11.050s | 8.210s | 0.540s | 1.337s | 0.964s | ~194x | ~59x |
| `builder_case_count` | 0.049s | 0.005s | 0.162s | 0.809s | 0.029s | 0.412s | 0.026s | ~3.3x | ~34x |
| `builder_c0_code_hash` вариант 0 | 0.054s | 0.006s | 0.237s | 0.771s | 0.036s | 0.432s | 0.028s | ~4.4x | ~38x |
| `builder_c1_code_hash` вариант 1 | 0.052s | 0.007s | 0.258s | 0.762s | 0.037s | 0.426s | 0.027s | ~5.0x | ~39x |
| `builder_c1_run_hash` вариант 1 | 0.047s | 0.006s | 0.261s | 0.731s | 0.038s | 0.427s | 0.029s | ~5.5x | ~40x |
| `builder_c2_code_hash` вариант 2 | 0.047s | 0.007s | 0.301s | 0.786s | 0.038s | 0.426s | 0.029s | ~6.4x | ~46x |
| `builder_c2_run_hash` вариант 2 | 0.048s | 0.007s | 0.264s | 0.757s | 0.046s | 0.435s | 0.027s | ~5.5x | ~40x |

Все результаты совпали с baseline (wasmtime 86/86, wasm3 C 86/86, wasm3das(inter) 86/86, wasm3das(aot) 86/86, wasm3das(aot_ctx) 86/86, wasm3das(jit) 86/86, wasm3das(exe) 86/86)

Ещё 12 строк(и) без документированного baseline остаются в таблице, их результат не проверяется.

## Итого (весь набор: основные + вариации)

| runtime | суммарное время | × к wasm3 C | старт (`fixtures/add`) | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasmtime | 3.400s | ~1.2x | 0.010s | 2.385s | ~0.9x |
| wasm3 C | 2.925s | ~1.0x | 0.001s | 2.788s | ~1.0x |
| wasm3das(inter) | 1m38.0s | ~34x | 0.157s | 1m22.7s | ~30x |
| wasm3das(aot) | 2m14.6s | ~46x | 0.770s | 59.119s | ~21x |
| wasm3das(aot_ctx) | 7.255s | ~2.5x | 0.027s | 4.640s | ~1.7x |
| wasm3das(jit) | 50.023s | ~17x | 0.416s | 9.267s | ~3.3x |
| wasm3das(exe) | 9.617s | ~3.3x | 0.023s | 7.411s | ~2.7x |

Старт это минимальное полное время среди строк без исполнения (`add`, `hash_f32`, `hash_f64`), «без старта» это сумма минус старт на каждую засчитанную строку: оценка рядом с честным полным временем, не вместо него.

## Прогон

- Date (UTC): 2026-09-20T20:45:04Z
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

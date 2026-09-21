# Spider manual fixtures: parity and timing

## Основные

По одной продакшен-конфигурации на модуль: самый тяжёлый реальный экспорт (декодер, полный цикл, длинная симуляция). Остальные экспорты и вариации аргументов — справочной таблицей ниже.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `add` 1 2 | 0.066s | 0.003s | 0.925s | 1.088s | 0.042s | 1.967s | 0.031s | ~14x | ~319x |
| `hash_loop` seed 123456789, 200000 итераций | 0.013s | 0.004s | 0.689s | 1.269s | 0.018s | 0.467s | 0.033s | ~51x | ~171x |
| `hash_f32` 2048 элементов | 0.012s | 0.001s | 0.181s | 0.830s | 0.014s | 0.440s | 0.023s | ~15x | ~135x |
| `hash_f64` 2048 элементов | 0.011s | 0.001s | 0.187s | 0.936s | 0.014s | 0.498s | 0.034s | ~17x | ~146x |
| `hash_i64_mix` 512 элементов | 0.018s | 0.002s | 0.196s | 0.885s | 0.014s | 0.460s | 0.023s | ~11x | ~108x |
| `hash_i64_div` 512 элементов | 0.012s | 0.001s | 0.202s | 0.905s | 0.014s | 0.452s | 0.023s | ~16x | ~164x |
| `tinyexpr_hash` 256 выражений | 0.017s | 0.002s | 0.259s | 0.823s | 0.015s | 0.455s | 0.026s | ~16x | ~105x |
| `miniz_roundtrip_hash` уровень 6 | 0.025s | 0.005s | 0.467s | 1.040s | 0.018s | 0.468s | 0.033s | ~18x | ~102x |
| `miniz_full_hash` уровень 6 | 0.032s | 0.011s | 0.588s | 1.201s | 0.021s | 0.487s | 0.036s | ~19x | ~53x |
| `miniz_file_hash` уровень 6 | 0.036s | 0.020s | 0.766s | 1.358s | 0.023s | 0.583s | 0.043s | ~22x | ~37x |
| `lodepng_roundtrip` картинка 1 | 0.037s | 0.032s | 1.600s | 1.985s | 0.031s | 0.529s | 0.069s | ~43x | ~51x |
| `chipmunk_hash_scene` 600 шагов | 0.024s | 0.066s | 4.967s | 5.015s | 0.084s | 0.763s | 0.237s | ~207x | ~75x |
| `secret_expected_crc32` | 0.025s | 0.003s | 0.173s | 0.819s | 0.014s | 0.441s | 0.023s | ~7.0x | ~68x |
| `profile_memory_walk` 400 итераций | 0.023s | 0.007s | 0.798s | 1.292s | 0.019s | 0.475s | 0.043s | ~35x | ~115x |
| `profile_math_shim` 400 итераций | 0.023s | 0.005s | 0.226s | 0.816s | 0.016s | 0.442s | 0.025s | ~9.9x | ~50x |
| `profile_branch_state` 400 итераций | 0.023s | 0.005s | 0.264s | 0.885s | 0.016s | 0.449s | 0.027s | ~12x | ~56x |
| `profile_space_freefall` 120 шагов | 0.022s | 0.006s | 0.358s | 0.943s | 0.017s | 0.461s | 0.028s | ~16x | ~62x |
| `profile_space_collision` 120 шагов | 0.024s | 0.015s | 1.117s | 1.518s | 0.027s | 0.486s | 0.055s | ~46x | ~74x |
| `profile_space_full` 120 шагов | 0.025s | 0.016s | 1.140s | 1.667s | 0.029s | 0.514s | 0.059s | ~45x | ~71x |
| `h264mp4_decode_hash` 8 кадров | 0.048s | 0.039s | 1.207s | 1.706s | 0.037s | 0.529s | 0.066s | ~25x | ~31x |
| `plmpeg_decode_hash` 8 кадров | 0.031s | 0.062s | 1.952s | 2.292s | 0.040s | 0.567s | 0.093s | ~63x | ~31x |
| `plmpeg_stream_decode_hash` 8 кадров | 0.023s | 0.063s | 1.944s | 2.308s | 0.040s | 0.563s | 0.092s | ~86x | ~31x |
| `libjpeg_decode_hash` | 0.065s | 0.034s | 1.030s | 1.609s | 0.029s | 0.513s | 0.058s | ~16x | ~30x |
| `mjpeg_decode_hash` 12 кадров | 0.080s | 0.049s | 2.255s | 2.607s | 0.041s | 0.574s | 0.099s | ~28x | ~46x |
| `binjgb_decode_hash` 16 кадров | 0.052s | 0.191s | 17.211s | 14.598s | 0.190s | 1.384s | 0.602s | ~334x | ~90x |
| `builder_c0_run_hash` вариант 0 | 0.052s | 0.007s | 0.277s | 0.906s | 0.019s | 0.465s | 0.030s | ~5.3x | ~42x |

| runtime | суммарное время (основные) | × к wasm3 C | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: |
| wasmtime | 0.817s | ~1.3x | 0.531s | ~0.9x |
| wasm3 C | 0.649s | ~1.0x | 0.616s | ~1.0x |
| wasm3das(inter) | 40.981s | ~63x | 36.262s | ~59x |
| wasm3das(aot) | 51.301s | ~79x | 29.709s | ~48x |
| wasm3das(aot_ctx) | 0.841s | ~1.3x | 0.487s | ~0.8x |
| wasm3das(jit) | 15.433s | ~24x | 4.004s | ~6.5x |
| wasm3das(exe) | 1.911s | ~2.9x | 1.303s | ~2.1x |

## Вариации аргументов и остальные экспорты

Справочные строки: остальные экспорты модулей, отладочные пробы и остальные конфигурации аргументов. Методика и колонки те же.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | wasm3das(exe) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hash_loop` seed 1, 65536 итераций | 0.011s | 0.002s | 0.334s | 0.977s | 0.015s | 0.467s | 0.026s | ~30x | ~155x |
| `probe_div_s64` | 0.012s | 0.001s | 0.189s | 0.939s | 0.014s | 0.431s | 0.022s | ~15x | ~159x |
| `probe_rem_s64` | 0.012s | 0.001s | 0.169s | 0.766s | 0.014s | 0.423s | 0.022s | ~14x | ~144x |
| `probe_div_u64` | 0.011s | 0.001s | 0.166s | 0.719s | 0.013s | 0.427s | 0.022s | ~14x | ~145x |
| `probe_rem_u64` | 0.011s | 0.001s | 0.165s | 0.691s | 0.014s | 0.443s | 0.024s | ~15x | ~128x |
| `tinyexpr_error_code` | 0.016s | 0.001s | 0.179s | 0.794s | 0.014s | 0.435s | 0.023s | ~11x | ~121x |
| `miniz_probe_compressed_size` уровень 6 | 0.025s | 0.004s | 0.388s | 0.887s | 0.017s | 0.454s | 0.030s | ~16x | ~106x |
| `miniz_probe_crc32` | 0.025s | 0.002s | 0.205s | 0.762s | 0.015s | 0.446s | 0.025s | ~8.3x | ~97x |
| `miniz_probe_adler32` | 0.025s | 0.002s | 0.200s | 0.752s | 0.015s | 0.437s | 0.026s | ~7.9x | ~97x |
| `miniz_probe_fold_hash` | 0.027s | 0.002s | 0.209s | 0.885s | 0.015s | 0.482s | 0.024s | ~7.8x | ~93x |
| `miniz_full_num_files` уровень 6 | 0.030s | 0.011s | 0.584s | 1.245s | 0.021s | 0.508s | 0.038s | ~19x | ~53x |
| `miniz_full_archive_size` уровень 6 | 0.030s | 0.011s | 0.598s | 1.301s | 0.021s | 0.556s | 0.038s | ~20x | ~56x |
| `miniz_full_locate_mix` уровень 6 | 0.031s | 0.011s | 0.604s | 1.297s | 0.029s | 0.523s | 0.039s | ~20x | ~55x |
| `miniz_full_extract_hash` уровень 6 | 0.032s | 0.012s | 0.601s | 1.298s | 0.021s | 0.569s | 0.040s | ~19x | ~52x |
| `miniz_full_validate` уровень 6 | 0.036s | 0.012s | 0.692s | 1.252s | 0.022s | 0.543s | 0.039s | ~19x | ~57x |
| `miniz_file_num_files` уровень 6 | 0.035s | 0.020s | 0.833s | 1.568s | 0.024s | 0.530s | 0.046s | ~24x | ~41x |
| `miniz_file_archive_size` уровень 6 | 0.033s | 0.021s | 0.711s | 1.343s | 0.025s | 0.508s | 0.043s | ~21x | ~33x |
| `miniz_file_extract_hash` уровень 6 | 0.031s | 0.021s | 0.793s | 1.469s | 0.024s | 0.493s | 0.044s | ~25x | ~38x |
| `miniz_file_in_place` уровень 6 | 0.033s | 0.020s | 0.714s | 1.215s | 0.025s | 0.487s | 0.041s | ~21x | ~35x |
| `lodepng_roundtrip` картинка 0 | 0.037s | 0.021s | 1.141s | 1.655s | 0.026s | 0.603s | 0.080s | ~31x | ~54x |
| `lodepng_encoded_size` картинка 0 | 0.040s | 0.022s | 1.077s | 1.758s | 0.027s | 0.536s | 0.052s | ~27x | ~50x |
| `lodepng_decode_hash` картинка 0 | 0.036s | 0.023s | 1.177s | 1.650s | 0.029s | 0.535s | 0.058s | ~33x | ~51x |
| `lodepng_input_hash` картинка 0 | 0.037s | 0.013s | 0.210s | 0.947s | 0.017s | 0.470s | 0.028s | ~5.6x | ~16x |
| `lodepng_png_hash` картинка 0 | 0.036s | 0.021s | 0.987s | 1.625s | 0.032s | 0.530s | 0.054s | ~28x | ~47x |
| `lodepng_encoded_size` картинка 1 | 0.036s | 0.023s | 1.317s | 1.808s | 0.028s | 0.522s | 0.061s | ~37x | ~57x |
| `lodepng_decode_hash` картинка 1 | 0.037s | 0.026s | 1.519s | 1.899s | 0.030s | 0.520s | 0.067s | ~41x | ~57x |
| `lodepng_input_hash` картинка 1 | 0.033s | 0.013s | 0.199s | 0.834s | 0.016s | 0.451s | 0.027s | ~6.1x | ~16x |
| `lodepng_png_hash` картинка 1 | 0.033s | 0.024s | 1.333s | 1.715s | 0.028s | 0.503s | 0.063s | ~40x | ~57x |
| `chipmunk_hash_scene` 60 шагов | 0.025s | 0.010s | 0.675s | 1.177s | 0.022s | 0.472s | 0.038s | ~27x | ~68x |
| `chipmunk_variant` 600 шагов | 0.027s | 0.088s | 6.375s | 6.126s | 0.098s | 0.827s | 0.291s | ~239x | ~73x |
| `chipmunk_probe_x` тело 0, 600 шагов | 0.025s | 0.065s | 5.004s | 5.002s | 0.081s | 0.735s | 0.230s | ~203x | ~77x |
| `chipmunk_probe_y` тело 1, 600 шагов | 0.026s | 0.063s | 5.006s | 4.948s | 0.080s | 0.736s | 0.227s | ~195x | ~79x |
| `chipmunk_probe_angle` тело 2, 600 шагов | 0.027s | 0.066s | 4.961s | 4.956s | 0.083s | 0.740s | 0.231s | ~186x | ~75x |
| `secret_expected_length` | 0.027s | 0.003s | 0.175s | 0.780s | 0.014s | 0.439s | 0.023s | ~6.6x | ~65x |
| `h264mp4_width` | 0.044s | 0.028s | 0.465s | 1.047s | 0.024s | 0.482s | 0.041s | ~11x | ~16x |
| `h264mp4_height` | 0.044s | 0.030s | 0.461s | 1.022s | 0.024s | 0.481s | 0.038s | ~10x | ~15x |
| `h264mp4_frame_count` 8 кадров | 0.046s | 0.041s | 1.196s | 1.638s | 0.033s | 0.520s | 0.068s | ~26x | ~29x |
| `h264mp4_first_frame` | 0.045s | 0.029s | 0.458s | 1.045s | 0.023s | 0.480s | 0.038s | ~10x | ~16x |
| `h264mp4_last_frame` 8 кадров | 0.045s | 0.039s | 1.196s | 1.650s | 0.034s | 0.545s | 0.067s | ~27x | ~30x |
| `plmpeg_width` | 0.030s | 0.047s | 0.474s | 1.114s | 0.026s | 0.487s | 0.042s | ~16x | ~10.0x |
| `plmpeg_height` | 0.029s | 0.048s | 0.469s | 1.133s | 0.025s | 0.484s | 0.042s | ~16x | ~9.7x |
| `plmpeg_frame_count` 8 кадров | 0.028s | 0.063s | 1.926s | 2.317s | 0.040s | 0.563s | 0.092s | ~70x | ~31x |
| `plmpeg_first_frame` | 0.030s | 0.048s | 0.470s | 1.093s | 0.025s | 0.479s | 0.042s | ~16x | ~9.9x |
| `plmpeg_last_frame` 8 кадров | 0.030s | 0.063s | 1.944s | 2.375s | 0.040s | 0.561s | 0.093s | ~66x | ~31x |
| `plmpeg_stream_width` | 0.021s | 0.047s | 0.477s | 1.117s | 0.025s | 0.493s | 0.040s | ~23x | ~10x |
| `plmpeg_stream_height` | 0.020s | 0.049s | 0.467s | 1.144s | 0.025s | 0.482s | 0.041s | ~23x | ~9.6x |
| `plmpeg_stream_frame_count` 8 кадров | 0.021s | 0.063s | 1.931s | 2.349s | 0.040s | 0.576s | 0.092s | ~93x | ~30x |
| `plmpeg_stream_first_frame` | 0.020s | 0.048s | 0.475s | 1.138s | 0.025s | 0.480s | 0.041s | ~23x | ~9.9x |
| `plmpeg_stream_last_frame` 8 кадров | 0.020s | 0.064s | 1.952s | 2.325s | 0.041s | 0.569s | 0.091s | ~100x | ~31x |
| `libjpeg_width` | 0.063s | 0.033s | 0.955s | 1.517s | 0.027s | 0.504s | 0.056s | ~15x | ~29x |
| `libjpeg_height` | 0.061s | 0.033s | 0.923s | 1.513s | 0.027s | 0.509s | 0.055s | ~15x | ~28x |
| `libjpeg_components` | 0.059s | 0.033s | 0.912s | 1.528s | 0.027s | 0.520s | 0.055s | ~15x | ~28x |
| `libjpeg_input_hash` | 0.062s | 0.025s | 0.191s | 0.939s | 0.019s | 0.534s | 0.031s | ~3.1x | ~7.7x |
| `libjpeg_rgb_size` | 0.066s | 0.034s | 0.936s | 1.614s | 0.029s | 0.537s | 0.057s | ~14x | ~27x |
| `mjpeg_width` | 0.059s | 0.027s | 0.394s | 1.009s | 0.023s | 0.481s | 0.035s | ~6.7x | ~14x |
| `mjpeg_height` | 0.061s | 0.027s | 0.396s | 1.015s | 0.022s | 0.473s | 0.035s | ~6.5x | ~15x |
| `mjpeg_components` | 0.062s | 0.028s | 0.396s | 0.997s | 0.022s | 0.468s | 0.035s | ~6.3x | ~14x |
| `mjpeg_frame_count` 12 кадров | 0.059s | 0.047s | 2.232s | 2.579s | 0.042s | 0.625s | 0.109s | ~38x | ~47x |
| `mjpeg_first_frame` | 0.067s | 0.030s | 0.432s | 1.092s | 0.021s | 0.467s | 0.035s | ~6.5x | ~15x |
| `mjpeg_last_frame` 12 кадров | 0.063s | 0.047s | 2.242s | 2.529s | 0.041s | 0.585s | 0.099s | ~36x | ~48x |
| `mjpeg_input_hash` | 0.059s | 0.025s | 0.213s | 0.887s | 0.019s | 0.464s | 0.028s | ~3.6x | ~8.7x |
| `binjgb_width` | 0.040s | 0.046s | 0.183s | 0.719s | 0.022s | 0.450s | 0.032s | ~4.6x | ~4.0x |
| `binjgb_height` | 0.040s | 0.047s | 0.183s | 0.779s | 0.024s | 0.453s | 0.031s | ~4.6x | ~3.9x |
| `binjgb_frame_count` 16 кадров | 0.051s | 0.196s | 17.578s | 16.844s | 0.225s | 1.593s | 0.685s | ~346x | ~90x |
| `binjgb_first_frame` | 0.046s | 0.064s | 1.432s | 1.772s | 0.040s | 0.593s | 0.074s | ~31x | ~22x |
| `binjgb_last_frame` 16 кадров | 0.056s | 0.225s | 18.804s | 15.450s | 0.188s | 1.363s | 0.589s | ~336x | ~83x |
| `builder_case_count` | 0.050s | 0.005s | 0.182s | 0.882s | 0.015s | 0.452s | 0.025s | ~3.6x | ~37x |
| `builder_c0_code_hash` вариант 0 | 0.047s | 0.006s | 0.263s | 0.890s | 0.018s | 0.456s | 0.029s | ~5.6x | ~41x |
| `builder_c1_code_hash` вариант 1 | 0.051s | 0.007s | 0.284s | 0.939s | 0.018s | 0.458s | 0.029s | ~5.5x | ~42x |
| `builder_c1_run_hash` вариант 1 | 0.051s | 0.007s | 0.282s | 0.931s | 0.019s | 0.464s | 0.028s | ~5.5x | ~43x |
| `builder_c2_code_hash` вариант 2 | 0.048s | 0.007s | 0.287s | 0.887s | 0.018s | 0.458s | 0.028s | ~6.0x | ~42x |
| `builder_c2_run_hash` вариант 2 | 0.049s | 0.007s | 0.289s | 0.950s | 0.018s | 0.462s | 0.028s | ~5.9x | ~41x |

Все результаты совпали с baseline (wasmtime 86/86, wasm3 C 86/86, wasm3das(inter) 86/86, wasm3das(aot) 86/86, wasm3das(aot_ctx) 86/86, wasm3das(jit) 86/86, wasm3das(exe) 86/86)

Ещё 12 строк(и) без документированного baseline остаются в таблице, их результат не проверяется.

## Итого (весь набор: основные + вариации)

| runtime | суммарное время | × к wasm3 C | старт (`fixtures/add`) | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasmtime | 3.505s | ~1.2x | 0.011s | 2.427s | ~0.8x |
| wasm3 C | 3.002s | ~1.0x | 0.001s | 2.876s | ~1.0x |
| wasm3das(inter) | 2m24.8s | ~48x | 0.181s | 2m07.0s | ~44x |
| wasm3das(aot) | 3m09.1s | ~63x | 0.830s | 1m47.7s | ~37x |
| wasm3das(aot_ctx) | 3.181s | ~1.1x | 0.014s | 1.849s | ~0.6x |
| wasm3das(jit) | 54.264s | ~18x | 0.440s | 11.186s | ~3.9x |
| wasm3das(exe) | 7.128s | ~2.4x | 0.023s | 4.838s | ~1.7x |

Старт это минимальное полное время среди строк без исполнения (`add`, `hash_f32`, `hash_f64`), «без старта» это сумма минус старт на каждую засчитанную строку: оценка рядом с честным полным временем, не вместо него.

## Прогон

- Date (UTC): 2026-09-21T19:55:49Z
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

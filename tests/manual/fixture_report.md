# Spider manual fixtures: parity and timing

## Основные

По одной продакшен-конфигурации на модуль: самый тяжёлый реальный экспорт (декодер, полный цикл, длинная симуляция). Остальные экспорты и вариации аргументов — справочной таблицей ниже.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `add` 1 2 | 0.061s | 0.003s | 0.808s | 0.703s | 0.032s | 2.011s | ~13x | ~277x |
| `hash_loop` seed 123456789, 200000 итераций | 0.014s | 0.004s | 0.526s | 0.855s | 0.048s | 0.592s | ~37x | ~121x |
| `hash_f32` 2048 элементов | 0.013s | 0.002s | 0.198s | 0.677s | 0.031s | 0.544s | ~15x | ~118x |
| `hash_f64` 2048 элементов | 0.012s | 0.002s | 0.197s | 0.705s | 0.032s | 0.554s | ~17x | ~106x |
| `hash_i64_mix` 512 элементов | 0.021s | 0.002s | 0.195s | 0.687s | 0.031s | 0.545s | ~9.4x | ~120x |
| `hash_i64_div` 512 элементов | 0.014s | 0.002s | 0.192s | 0.715s | 0.032s | 0.552s | ~14x | ~123x |
| `tinyexpr_hash` 256 выражений | 0.018s | 0.003s | 0.262s | 0.756s | 0.036s | 0.551s | ~14x | ~99x |
| `miniz_roundtrip_hash` уровень 6 | 0.029s | 0.005s | 0.417s | 0.795s | 0.044s | 0.581s | ~14x | ~81x |
| `miniz_full_hash` уровень 6 | 0.032s | 0.012s | 0.485s | 0.813s | 0.048s | 0.572s | ~15x | ~42x |
| `miniz_file_hash` уровень 6 | 0.035s | 0.022s | 0.573s | 0.903s | 0.055s | 0.577s | ~17x | ~26x |
| `lodepng_roundtrip` картинка 1 | 0.039s | 0.027s | 1.157s | 1.266s | 0.084s | 0.653s | ~30x | ~42x |
| `chipmunk_hash_scene` 600 шагов | 0.027s | 0.070s | 3.711s | 3.069s | 0.215s | 0.888s | ~136x | ~53x |
| `secret_expected_crc32` | 0.027s | 0.003s | 0.205s | 0.682s | 0.032s | 0.575s | ~7.5x | ~67x |
| `profile_memory_walk` 400 итераций | 0.029s | 0.008s | 0.636s | 0.985s | 0.051s | 0.590s | ~22x | ~76x |
| `profile_math_shim` 400 итераций | 0.025s | 0.005s | 0.231s | 0.731s | 0.035s | 0.575s | ~9.2x | ~47x |
| `profile_branch_state` 400 итераций | 0.025s | 0.005s | 0.253s | 0.725s | 0.035s | 0.559s | ~10x | ~50x |
| `profile_space_freefall` 120 шагов | 0.025s | 0.006s | 0.330s | 0.772s | 0.039s | 0.577s | ~13x | ~53x |
| `profile_space_collision` 120 шагов | 0.025s | 0.016s | 0.914s | 1.067s | 0.068s | 0.621s | ~37x | ~57x |
| `profile_space_full` 120 шагов | 0.026s | 0.016s | 0.899s | 1.151s | 0.072s | 0.611s | ~35x | ~56x |
| `h264mp4_decode_hash` 8 кадров | 0.050s | 0.041s | 0.923s | 1.094s | 0.077s | 0.637s | ~19x | ~22x |
| `plmpeg_decode_hash` 8 кадров | 0.030s | 0.067s | 1.390s | 1.442s | 0.099s | 0.702s | ~46x | ~21x |
| `plmpeg_stream_decode_hash` 8 кадров | 0.022s | 0.068s | 1.370s | 1.427s | 0.095s | 0.675s | ~61x | ~20x |
| `libjpeg_decode_hash` | 0.064s | 0.035s | 0.784s | 1.053s | 0.068s | 0.635s | ~12x | ~22x |
| `mjpeg_decode_hash` 12 кадров | 0.064s | 0.049s | 1.607s | 1.554s | 0.105s | 0.683s | ~25x | ~33x |
| `binjgb_decode_hash` 16 кадров | 0.060s | 0.219s | 11.882s | 8.145s | 0.587s | 1.474s | ~197x | ~54x |
| `builder_c0_run_hash` вариант 0 | 0.049s | 0.007s | 0.291s | 0.714s | 0.042s | 0.563s | ~6.0x | ~43x |

| runtime | суммарное время (основные) | × к wasm3 C | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: |
| wasmtime | 0.835s | ~1.2x | 0.526s | ~0.8x |
| wasm3 C | 0.699s | ~1.0x | 0.655s | ~1.0x |
| wasm3das(inter) | 30.436s | ~44x | 25.327s | ~39x |
| wasm3das(aot) | 33.486s | ~48x | 15.891s | ~24x |
| wasm3das(aot_ctx) | 2.092s | ~3.0x | 1.277s | ~1.9x |
| wasm3das(jit) | 18.096s | ~26x | 3.960s | ~6.0x |

## Вариации аргументов и остальные экспорты

Справочные строки: остальные экспорты модулей, отладочные пробы и остальные конфигурации аргументов. Методика и колонки те же.

| Тест | wasmtime | wasm3 C | wasm3das(inter) | wasm3das(aot) | wasm3das(aot_ctx) | wasm3das(jit) | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hash_loop` seed 1, 65536 итераций | 0.012s | 0.003s | 0.298s | 0.722s | 0.036s | 0.562s | ~25x | ~118x |
| `probe_div_s64` | 0.013s | 0.001s | 0.191s | 0.704s | 0.032s | 0.570s | ~15x | ~144x |
| `probe_rem_s64` | 0.013s | 0.002s | 0.191s | 0.747s | 0.031s | 0.561s | ~15x | ~124x |
| `probe_div_u64` | 0.013s | 0.001s | 0.189s | 0.688s | 0.032s | 0.549s | ~14x | ~127x |
| `probe_rem_u64` | 0.013s | 0.001s | 0.189s | 0.703s | 0.032s | 0.554s | ~15x | ~126x |
| `tinyexpr_error_code` | 0.017s | 0.002s | 0.193s | 0.718s | 0.033s | 0.565s | ~11x | ~114x |
| `miniz_probe_compressed_size` уровень 6 | 0.028s | 0.004s | 0.351s | 0.830s | 0.041s | 0.592s | ~13x | ~82x |
| `miniz_probe_crc32` | 0.029s | 0.002s | 0.231s | 0.804s | 0.034s | 0.559s | ~7.9x | ~93x |
| `miniz_probe_adler32` | 0.026s | 0.002s | 0.209s | 0.868s | 0.033s | 0.552s | ~7.9x | ~86x |
| `miniz_probe_fold_hash` | 0.026s | 0.002s | 0.208s | 0.685s | 0.033s | 0.549s | ~8.0x | ~88x |
| `miniz_full_num_files` уровень 6 | 0.033s | 0.012s | 0.486s | 0.868s | 0.050s | 0.579s | ~15x | ~42x |
| `miniz_full_archive_size` уровень 6 | 0.031s | 0.012s | 0.491s | 0.895s | 0.051s | 0.573s | ~16x | ~41x |
| `miniz_full_locate_mix` уровень 6 | 0.032s | 0.011s | 0.489s | 0.842s | 0.047s | 0.591s | ~15x | ~43x |
| `miniz_full_extract_hash` уровень 6 | 0.033s | 0.012s | 0.485s | 0.873s | 0.049s | 0.574s | ~15x | ~40x |
| `miniz_full_validate` уровень 6 | 0.034s | 0.012s | 0.486s | 0.810s | 0.048s | 0.574s | ~14x | ~41x |
| `miniz_file_num_files` уровень 6 | 0.038s | 0.022s | 0.572s | 0.887s | 0.054s | 0.581s | ~15x | ~26x |
| `miniz_file_archive_size` уровень 6 | 0.033s | 0.022s | 0.570s | 0.885s | 0.053s | 0.579s | ~17x | ~25x |
| `miniz_file_extract_hash` уровень 6 | 0.033s | 0.022s | 0.580s | 0.878s | 0.054s | 0.585s | ~18x | ~27x |
| `miniz_file_in_place` уровень 6 | 0.034s | 0.022s | 0.567s | 0.922s | 0.058s | 0.600s | ~17x | ~26x |
| `lodepng_roundtrip` картинка 0 | 0.037s | 0.023s | 0.867s | 1.049s | 0.068s | 0.607s | ~23x | ~37x |
| `lodepng_encoded_size` картинка 0 | 0.038s | 0.022s | 0.750s | 1.039s | 0.066s | 0.631s | ~20x | ~34x |
| `lodepng_decode_hash` картинка 0 | 0.037s | 0.024s | 0.870s | 1.073s | 0.070s | 0.613s | ~23x | ~36x |
| `lodepng_input_hash` картинка 0 | 0.035s | 0.013s | 0.205s | 0.716s | 0.034s | 0.557s | ~5.8x | ~16x |
| `lodepng_png_hash` картинка 0 | 0.038s | 0.021s | 0.757s | 0.994s | 0.061s | 0.596s | ~20x | ~36x |
| `lodepng_encoded_size` картинка 1 | 0.037s | 0.026s | 0.998s | 1.160s | 0.073s | 0.609s | ~27x | ~39x |
| `lodepng_decode_hash` картинка 1 | 0.035s | 0.029s | 1.131s | 1.234s | 0.084s | 0.626s | ~32x | ~40x |
| `lodepng_input_hash` картинка 1 | 0.035s | 0.013s | 0.206s | 0.711s | 0.035s | 0.564s | ~5.9x | ~16x |
| `lodepng_png_hash` картинка 1 | 0.035s | 0.025s | 0.997s | 1.160s | 0.073s | 0.617s | ~28x | ~40x |
| `chipmunk_hash_scene` 60 шагов | 0.026s | 0.010s | 0.576s | 0.886s | 0.052s | 0.578s | ~22x | ~56x |
| `chipmunk_variant` 600 шагов | 0.028s | 0.091s | 4.679s | 3.657s | 0.263s | 0.954s | ~168x | ~51x |
| `chipmunk_probe_x` тело 0, 600 шагов | 0.027s | 0.071s | 3.737s | 3.019s | 0.216s | 0.876s | ~137x | ~53x |
| `chipmunk_probe_y` тело 1, 600 шагов | 0.027s | 0.071s | 3.732s | 3.008s | 0.218s | 0.866s | ~139x | ~52x |
| `chipmunk_probe_angle` тело 2, 600 шагов | 0.028s | 0.072s | 3.759s | 3.025s | 0.214s | 0.870s | ~134x | ~52x |
| `secret_expected_length` | 0.029s | 0.003s | 0.191s | 0.827s | 0.032s | 0.614s | ~6.6x | ~67x |
| `h264mp4_width` | 0.044s | 0.029s | 0.416s | 0.803s | 0.051s | 0.573s | ~9.6x | ~14x |
| `h264mp4_height` | 0.045s | 0.029s | 0.415s | 0.796s | 0.053s | 0.568s | ~9.2x | ~14x |
| `h264mp4_frame_count` 8 кадров | 0.047s | 0.042s | 0.918s | 1.071s | 0.078s | 0.619s | ~20x | ~22x |
| `h264mp4_first_frame` | 0.043s | 0.029s | 0.416s | 0.788s | 0.051s | 0.571s | ~9.6x | ~14x |
| `h264mp4_last_frame` 8 кадров | 0.045s | 0.042s | 0.924s | 1.109s | 0.079s | 0.617s | ~21x | ~22x |
| `plmpeg_width` | 0.030s | 0.054s | 0.410s | 0.823s | 0.049s | 0.611s | ~14x | ~7.6x |
| `plmpeg_height` | 0.034s | 0.052s | 0.402s | 0.816s | 0.050s | 0.578s | ~12x | ~7.8x |
| `plmpeg_frame_count` 8 кадров | 0.029s | 0.067s | 1.371s | 1.445s | 0.095s | 0.670s | ~47x | ~20x |
| `plmpeg_first_frame` | 0.032s | 0.051s | 0.393s | 0.797s | 0.050s | 0.574s | ~12x | ~7.8x |
| `plmpeg_last_frame` 8 кадров | 0.031s | 0.068s | 1.372s | 1.488s | 0.096s | 0.658s | ~44x | ~20x |
| `plmpeg_stream_width` | 0.022s | 0.051s | 0.393s | 0.834s | 0.049s | 0.577s | ~18x | ~7.7x |
| `plmpeg_stream_height` | 0.020s | 0.052s | 0.399s | 0.799s | 0.049s | 0.574s | ~19x | ~7.7x |
| `plmpeg_stream_frame_count` 8 кадров | 0.021s | 0.067s | 1.374s | 1.378s | 0.096s | 0.656s | ~66x | ~21x |
| `plmpeg_stream_first_frame` | 0.020s | 0.051s | 0.390s | 0.799s | 0.049s | 0.573s | ~19x | ~7.6x |
| `plmpeg_stream_last_frame` 8 кадров | 0.022s | 0.068s | 1.373s | 1.431s | 0.095s | 0.655s | ~63x | ~20x |
| `libjpeg_width` | 0.072s | 0.036s | 0.741s | 1.029s | 0.065s | 0.647s | ~10x | ~21x |
| `libjpeg_height` | 0.059s | 0.033s | 0.706s | 1.019s | 0.062s | 0.605s | ~12x | ~21x |
| `libjpeg_components` | 0.062s | 0.034s | 0.740s | 0.988s | 0.062s | 0.600s | ~12x | ~22x |
| `libjpeg_input_hash` | 0.061s | 0.025s | 0.201s | 0.711s | 0.040s | 0.558s | ~3.3x | ~8.1x |
| `libjpeg_rgb_size` | 0.060s | 0.034s | 0.707s | 1.004s | 0.065s | 0.603s | ~12x | ~21x |
| `mjpeg_width` | 0.059s | 0.028s | 0.360s | 0.767s | 0.048s | 0.585s | ~6.1x | ~13x |
| `mjpeg_height` | 0.059s | 0.027s | 0.365s | 0.758s | 0.047s | 0.578s | ~6.1x | ~13x |
| `mjpeg_components` | 0.060s | 0.028s | 0.362s | 0.805s | 0.053s | 0.580s | ~6.0x | ~13x |
| `mjpeg_frame_count` 12 кадров | 0.067s | 0.049s | 1.618s | 1.567s | 0.105s | 0.677s | ~24x | ~33x |
| `mjpeg_first_frame` | 0.060s | 0.028s | 0.365s | 0.811s | 0.047s | 0.578s | ~6.1x | ~13x |
| `mjpeg_last_frame` 12 кадров | 0.063s | 0.049s | 1.606s | 1.564s | 0.104s | 0.687s | ~25x | ~33x |
| `mjpeg_input_hash` | 0.061s | 0.025s | 0.214s | 0.816s | 0.038s | 0.596s | ~3.5x | ~8.5x |
| `binjgb_width` | 0.044s | 0.048s | 0.203s | 0.718s | 0.040s | 0.559s | ~4.6x | ~4.2x |
| `binjgb_height` | 0.045s | 0.048s | 0.199s | 0.729s | 0.040s | 0.567s | ~4.5x | ~4.2x |
| `binjgb_frame_count` 16 кадров | 0.054s | 0.208s | 11.968s | 8.200s | 0.568s | 1.472s | ~223x | ~57x |
| `binjgb_first_frame` | 0.044s | 0.058s | 0.953s | 1.117s | 0.078s | 0.616s | ~22x | ~16x |
| `binjgb_last_frame` 16 кадров | 0.054s | 0.210s | 12.144s | 8.169s | 0.574s | 1.467s | ~226x | ~58x |
| `builder_case_count` | 0.053s | 0.005s | 0.193s | 0.745s | 0.034s | 0.579s | ~3.6x | ~38x |
| `builder_c0_code_hash` вариант 0 | 0.049s | 0.007s | 0.290s | 0.727s | 0.042s | 0.555s | ~5.9x | ~43x |
| `builder_c1_code_hash` вариант 1 | 0.049s | 0.007s | 0.297s | 0.682s | 0.044s | 0.570s | ~6.1x | ~43x |
| `builder_c1_run_hash` вариант 1 | 0.051s | 0.007s | 0.297s | 0.724s | 0.044s | 0.560s | ~5.8x | ~42x |
| `builder_c2_code_hash` вариант 2 | 0.051s | 0.008s | 0.309s | 0.730s | 0.044s | 0.560s | ~6.0x | ~41x |
| `builder_c2_run_hash` вариант 2 | 0.049s | 0.007s | 0.306s | 0.681s | 0.043s | 0.557s | ~6.3x | ~42x |

Все результаты совпали с baseline (wasmtime 86/86, wasm3 C 86/86, wasm3das(inter) 86/86, wasm3das(aot) 86/86, wasm3das(aot_ctx) 86/86, wasm3das(jit) 86/86)

Ещё 12 строк(и) без документированного baseline остаются в таблице, их результат не проверяется.

## Итого (весь набор: основные + вариации)

| runtime | суммарное время | × к wasm3 C | старт (`fixtures/add`) | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasmtime | 3.587s | ~1.1x | 0.012s | 2.425s | ~0.8x |
| wasm3 C | 3.139s | ~1.0x | 0.002s | 2.975s | ~1.0x |
| wasm3das(inter) | 1m47.0s | ~34x | 0.197s | 1m27.7s | ~29x |
| wasm3das(aot) | 2m02.6s | ~39x | 0.677s | 56.289s | ~19x |
| wasm3das(aot_ctx) | 7.729s | ~2.5x | 0.031s | 4.653s | ~1.6x |
| wasm3das(jit) | 1m03.6s | ~20x | 0.544s | 10.274s | ~3.5x |

Старт это минимальное полное время среди строк без исполнения (`add`, `hash_f32`, `hash_f64`), «без старта» это сумма минус старт на каждую засчитанную строку: оценка рядом с честным полным временем, не вместо него.

## Прогон

- Date (UTC): 2026-09-10T14:05:03Z
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
- wasm3das(jit): `DASLANG=/root/daScript/bin/daslang WASM3DAS_JIT=1 WASM3DAS_JIT_OPTS=--jit-opt-level=3 /root/wasm3das/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4

## Skipped entries

- `test_pure/render_frame 0.0` — runs ~400M float iterations; interpreter-in-interpreter would take hours
- `i64 probe_hash_i64_div_*_0/1` — debug probes, need i64 args, no documented baselines
- `host-adapter paths (gltf_rs, cgltf, wasm3, archive-secret extract, lodepng/plmpeg-stream host, lodepng_diag)` — need a Daslang memory-adapter driver, out of scope here
- `real-world-smollm2` — no wasm module built (upstream blocker on tensor callbacks)

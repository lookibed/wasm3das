# Spider manual fixtures: parity and timing

| Тест | wasmtime | wasm3 C | wasm3das | × к wasmtime | × к wasm3 C |
| --- | ---: | ---: | ---: | ---: | ---: |
| `add` 1 2 | 0.013s | 0.002s | 1.527s | ~114x | ~911x |
| `hash_loop` seed 123456789, 200000 итераций | 0.009s | 0.006s | 2.166s | ~244x | ~346x |
| `hash_loop` seed 1, 65536 итераций | 0.007s | 0.003s | 1.650s | ~222x | ~603x |
| `hash_f32` 2048 элементов | 0.009s | 0.002s | 1.423s | ~152x | ~926x |
| `hash_f64` 2048 элементов | 0.008s | 0.002s | 1.445s | ~172x | ~661x |
| `hash_i64_mix` 512 элементов | 0.011s | 0.002s | 1.453s | ~130x | ~789x |
| `hash_i64_div` 512 элементов | 0.011s | 0.002s | 1.384s | ~126x | ~871x |
| `probe_div_s64` | 0.010s | 0.002s | 1.288s | ~129x | ~754x |
| `probe_rem_s64` | 0.010s | 0.001s | 1.179s | ~122x | ~852x |
| `probe_div_u64` | 0.010s | 0.001s | 1.185s | ~120x | ~862x |
| `probe_rem_u64` | 0.010s | 0.001s | 1.158s | ~119x | ~819x |
| `tinyexpr_hash` 256 выражений | 0.024s | 0.003s | 1.295s | ~53x | ~387x |
| `tinyexpr_error_code` | 0.023s | 0.002s | 1.197s | ~52x | ~586x |
| `miniz_roundtrip_hash` уровень 6 | 0.040s | 0.005s | 1.578s | ~39x | ~307x |
| `miniz_probe_compressed_size` уровень 6 | 0.039s | 0.004s | 1.465s | ~38x | ~342x |
| `miniz_probe_crc32` | 0.039s | 0.003s | 1.215s | ~31x | ~483x |
| `miniz_probe_adler32` | 0.039s | 0.002s | 1.206s | ~31x | ~484x |
| `miniz_probe_fold_hash` | 0.040s | 0.003s | 1.231s | ~31x | ~486x |
| `miniz_full_hash` уровень 6 | 0.050s | 0.009s | 1.697s | ~34x | ~193x |
| `miniz_full_num_files` уровень 6 | 0.054s | 0.009s | 1.743s | ~32x | ~195x |
| `miniz_full_archive_size` уровень 6 | 0.053s | 0.009s | 1.746s | ~33x | ~200x |
| `miniz_full_locate_mix` уровень 6 | 0.052s | 0.009s | 1.723s | ~33x | ~190x |
| `miniz_full_extract_hash` уровень 6 | 0.056s | 0.009s | 1.678s | ~30x | ~190x |
| `miniz_full_validate` уровень 6 | 0.050s | 0.009s | 1.714s | ~34x | ~196x |
| `miniz_file_hash` уровень 6 | 0.064s | 0.013s | 1.892s | ~30x | ~144x |
| `miniz_file_num_files` уровень 6 | 0.066s | 0.013s | 1.863s | ~28x | ~140x |
| `miniz_file_archive_size` уровень 6 | 0.067s | 0.013s | 1.856s | ~28x | ~143x |
| `miniz_file_extract_hash` уровень 6 | 0.058s | 0.013s | 1.904s | ~33x | ~148x |
| `miniz_file_in_place` уровень 6 | 0.066s | 0.013s | 1.858s | ~28x | ~144x |
| `lodepng_roundtrip` картинка 0 | 0.087s | 0.015s | 2.348s | ~27x | ~157x |
| `lodepng_encoded_size` картинка 0 | 0.083s | 0.014s | 2.245s | ~27x | ~165x |
| `lodepng_decode_hash` картинка 0 | 0.083s | 0.014s | 2.337s | ~28x | ~167x |
| `lodepng_input_hash` картинка 0 | 0.086s | 0.007s | 1.184s | ~14x | ~178x |
| `lodepng_png_hash` картинка 0 | 0.095s | 0.012s | 2.188s | ~23x | ~176x |
| `lodepng_roundtrip` картинка 1 | 0.085s | 0.018s | 2.889s | ~34x | ~159x |
| `lodepng_encoded_size` картинка 1 | 0.084s | 0.016s | 2.712s | ~32x | ~168x |
| `lodepng_decode_hash` картинка 1 | 0.085s | 0.017s | 2.874s | ~34x | ~169x |
| `lodepng_input_hash` картинка 1 | 0.082s | 0.007s | 1.210s | ~15x | ~184x |
| `lodepng_png_hash` картинка 1 | 0.085s | 0.016s | 2.637s | ~31x | ~162x |
| `chipmunk_hash_scene` 60 шагов | 0.053s | 0.009s | 1.891s | ~36x | ~200x |
| `chipmunk_hash_scene` 600 шагов | 0.059s | 0.070s | 7.068s | ~120x | ~101x |
| `chipmunk_variant` 600 шагов | 0.059s | 0.086s | 8.935s | ~152x | ~104x |
| `chipmunk_probe_x` тело 0, 600 шагов | 0.057s | 0.069s | 7.224s | ~127x | ~104x |
| `chipmunk_probe_y` тело 1, 600 шагов | 0.056s | 0.071s | 7.274s | ~130x | ~103x |
| `chipmunk_probe_angle` тело 2, 600 шагов | 0.058s | 0.071s | 6.974s | ~120x | ~98x |
| `secret_expected_length` | 0.035s | 0.003s | 1.177s | ~34x | ~372x |
| `secret_expected_crc32` | 0.034s | 0.003s | 1.175s | ~34x | ~381x |
| `profile_memory_walk` 400 итераций | 0.052s | 0.008s | 1.978s | ~38x | ~261x |
| `profile_math_shim` 400 итераций | 0.053s | 0.004s | 1.271s | ~24x | ~298x |
| `profile_branch_state` 400 итераций | 0.056s | 0.004s | 1.291s | ~23x | ~290x |
| `profile_space_freefall` 120 шагов | 0.053s | 0.005s | 1.405s | ~27x | ~259x |
| `profile_space_collision` 120 шагов | 0.055s | 0.015s | 2.411s | ~44x | ~159x |
| `profile_space_full` 120 шагов | 0.056s | 0.015s | 2.459s | ~44x | ~169x |
| `h264mp4_decode_hash` 8 кадров | 0.126s | 0.026s | 2.450s | ~19x | ~94x |
| `h264mp4_width` | 0.131s | 0.015s | 1.602s | ~12x | ~106x |
| `h264mp4_height` | 0.125s | 0.015s | 1.591s | ~13x | ~106x |
| `h264mp4_frame_count` 8 кадров | 0.125s | 0.026s | 2.503s | ~20x | ~98x |
| `h264mp4_first_frame` | 0.141s | 0.015s | 1.603s | ~11x | ~103x |
| `h264mp4_last_frame` 8 кадров | 0.126s | 0.026s | 2.491s | ~20x | ~96x |
| `plmpeg_decode_hash` 8 кадров | 0.068s | 0.030s | 3.343s | ~49x | ~110x |
| `plmpeg_width` | 0.065s | 0.019s | 1.530s | ~24x | ~78x |
| `plmpeg_height` | 0.067s | 0.020s | 1.586s | ~24x | ~80x |
| `plmpeg_frame_count` 8 кадров | 0.068s | 0.031s | 3.306s | ~49x | ~108x |
| `plmpeg_first_frame` | 0.068s | 0.020s | 1.547s | ~23x | ~77x |
| `plmpeg_last_frame` 8 кадров | 0.069s | 0.031s | 3.442s | ~50x | ~111x |
| `plmpeg_stream_decode_hash` 8 кадров | 0.031s | 0.041s | 3.284s | ~105x | ~80x |
| `plmpeg_stream_width` | 0.029s | 0.020s | 1.519s | ~52x | ~76x |
| `plmpeg_stream_height` | 0.030s | 0.020s | 1.568s | ~52x | ~80x |
| `plmpeg_stream_frame_count` 8 кадров | 0.033s | 0.031s | 3.314s | ~101x | ~108x |
| `plmpeg_stream_first_frame` | 0.030s | 0.020s | 1.547s | ~52x | ~78x |
| `plmpeg_stream_last_frame` 8 кадров | 0.033s | 0.035s | 3.252s | ~100x | ~94x |
| `libjpeg_decode_hash` | 0.242s | 0.018s | 2.342s | ~9.7x | ~133x |
| `libjpeg_width` | 0.237s | 0.017s | 2.179s | ~9.2x | ~129x |
| `libjpeg_height` | 0.237s | 0.017s | 2.046s | ~8.6x | ~121x |
| `libjpeg_components` | 0.246s | 0.017s | 2.044s | ~8.3x | ~120x |
| `libjpeg_input_hash` | 0.238s | 0.010s | 1.206s | ~5.1x | ~116x |
| `libjpeg_rgb_size` | 0.235s | 0.018s | 2.103s | ~8.9x | ~120x |
| `mjpeg_decode_hash` 12 кадров | 0.248s | 0.027s | 3.677s | ~15x | ~135x |
| `mjpeg_width` | 0.238s | 0.013s | 1.491s | ~6.3x | ~112x |
| `mjpeg_height` | 0.236s | 0.013s | 1.481s | ~6.3x | ~114x |
| `mjpeg_components` | 0.240s | 0.013s | 1.575s | ~6.6x | ~121x |
| `mjpeg_frame_count` 12 кадров | 0.244s | 0.030s | 3.722s | ~15x | ~126x |
| `mjpeg_first_frame` | 0.238s | 0.013s | 1.519s | ~6.4x | ~119x |
| `mjpeg_last_frame` 12 кадров | 0.240s | 0.027s | 3.804s | ~16x | ~139x |
| `mjpeg_input_hash` | 0.237s | 0.011s | 1.226s | ~5.2x | ~111x |
| `binjgb_decode_hash` 16 кадров | 0.093s | 0.160s | 23.135s | ~248x | ~145x |
| `binjgb_width` | 0.077s | 0.017s | 1.188s | ~15x | ~69x |
| `binjgb_height` | 0.071s | 0.019s | 1.191s | ~17x | ~64x |
| `binjgb_frame_count` 16 кадров | 0.092s | 0.164s | 23.197s | ~253x | ~142x |
| `binjgb_first_frame` | 0.076s | 0.028s | 2.543s | ~34x | ~90x |
| `binjgb_last_frame` 16 кадров | 0.098s | 0.161s | 22.430s | ~228x | ~139x |
| `builder_case_count` | 0.116s | 0.004s | 1.193s | ~10x | ~267x |
| `builder_c0_code_hash` вариант 0 | 0.109s | 0.006s | 1.336s | ~12x | ~220x |
| `builder_c0_run_hash` вариант 0 | 0.126s | 0.007s | 1.334s | ~11x | ~188x |
| `builder_c1_code_hash` вариант 1 | 0.116s | 0.006s | 1.347s | ~12x | ~209x |
| `builder_c1_run_hash` вариант 1 | 0.103s | 0.007s | 1.373s | ~13x | ~188x |
| `builder_c2_code_hash` вариант 2 | 0.117s | 0.006s | 1.387s | ~12x | ~219x |
| `builder_c2_run_hash` вариант 2 | 0.107s | 0.008s | 1.382s | ~13x | ~183x |

Все результаты совпали с baseline (wasmtime 86/86, wasm3 C 86/86, wasm3das 86/86)

Ещё 12 строк(и) без документированного baseline остаются в таблице, их результат не проверяется.

## Итого

| runtime | суммарное время | × к wasm3 C | старт (`fixtures/add`) | без старта (оценка) | × к wasm3 C без старта |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasmtime | 8.602s | ~4.3x | 0.013s | 7.285s | ~3.9x |
| wasm3 C | 2.013s | ~1.0x | 0.002s | 1.849s | ~1.0x |
| wasm3das | 4m34.8s | ~136x | 1.527s | 2m05.1s | ~68x |

Старт это полное время строки `fixtures/add` (исполнения там нет), «без старта» это сумма минус старт на каждую засчитанную строку: оценка рядом с честным полным временем, не вместо него.

## Прогон

- Date (UTC): 2026-09-09T00:09:32Z
- Machine: Intel(R) Core(TM) i5-6200U CPU @ 2.30GHz (4 logical CPUs)
- Platform: Linux-6.12.107+deb13-amd64-x86_64-with-glibc2.41
- Checks: 98 x 3 runtimes
- Invocation: `tests/manual/run_fixtures.py --runtimes wasmtime,wasm3,das`

Runtimes:

- wasmtime: `/home/andry/wasm3das/tools/bin/wasmtime` — wasmtime 48.0.1 (7bac2c277 2026-08-24)
- wasm3 C: `/home/andry/wasm3das/tools/bin/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Sep  6 2026 21:52:29, GCC 14.2.0
- wasm3das: `/home/andry/wasm3das/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4

## Skipped entries

- `test_pure/render_frame 0.0` — runs ~400M float iterations; interpreter-in-interpreter would take hours
- `i64 probe_hash_i64_div_*_0/1` — debug probes, need i64 args, no documented baselines
- `host-adapter paths (gltf_rs, cgltf, wasm3, archive-secret extract, lodepng/plmpeg-stream host, lodepng_diag)` — need a Daslang memory-adapter driver, out of scope here
- `real-world-smollm2` — no wasm module built (upstream blocker on tensor callbacks)

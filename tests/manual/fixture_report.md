# Spider manual fixtures: parity and timing

- Date (UTC): 2026-09-07T07:42:25Z
- Machine: Intel(R) Core(TM) i5-6200U CPU @ 2.30GHz (4 logical CPUs)
- Platform: Linux-6.12.107+deb13-amd64-x86_64-with-glibc2.41
- Checks: 98 x 3 runtimes
- Invocation: `tests/manual/run_fixtures.py`

Runtimes:

- wasmtime: `/home/andry/wasm3das/tools/bin/wasmtime` — wasmtime 48.0.1 (7bac2c277 2026-08-24)
- wasm3 (original C): `/home/andry/wasm3das/tools/bin/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Sep  6 2026 21:52:29, GCC 14.2.0
- wasm3das: `/home/andry/wasm3das/scripts/wasm3` — Wasm3 v0.5.2 on x86_64 / Build: Daslang port, Daslang 0.6.4

## Results

A result is plain when it matches the documented wasmtime baseline, **bold with ✗** when it does not, and *italic* when the fixture has no documented baseline.

| test | baseline | wasmtime result | wasmtime time | wasm3 (original C) result | wasm3 (original C) time | wasm3das result | wasm3das time |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| fixtures/add | 3 | 3 | 0.007s | 3 | 0.001s | 3 | 2.022s |
| hash_loop 123456789 200000 | -1767246609 | -1767246609 | 0.008s | -1767246609 | 0.005s | -1767246609 | 3.023s |
| hash_loop 1 65536 | 1645510779 | 1645510779 | 0.008s | 1645510779 | 0.003s | 1645510779 | 2.278s |
| hash_f32 2048 | 206320613 | 206320613 | 0.008s | 206320613 | 0.002s | 206320613 | 2.012s |
| hash_f64 2048 | -736305322 | -736305322 | 0.008s | -736305322 | 0.001s | -736305322 | 1.987s |
| hash_i64_mix 512 | -921783428 | -921783428 | 0.010s | -921783428 | 0.001s | -921783428 | 1.992s |
| hash_i64_div 512 | -1398093681 | -1398093681 | 0.010s | -1398093681 | 0.001s | -1398093681 | 1.928s |
| probe_div_s64 | 674596155 | 674596155 | 0.010s | 674596155 | 0.001s | 674596155 | 1.927s |
| probe_rem_s64 | 0 | 0 | 0.010s | 0 | 0.001s | 0 | 1.939s |
| probe_div_u64 | 1290282190 | 1290282190 | 0.010s | 1290282190 | 0.001s | 1290282190 | 2.054s |
| probe_rem_u64 | 0 | 0 | 0.010s | 0 | 0.001s | 0 | 1.999s |
| tinyexpr_hash 256 | 141480662 | 141480662 | 0.023s | 141480662 | 0.003s | 141480662 | 2.363s |
| tinyexpr_error_code | 6 | 6 | 0.028s | 6 | 0.002s | 6 | 2.268s |
| miniz_roundtrip_hash 6 | 58679047 | 58679047 | 0.048s | 58679047 | 0.005s | 58679047 | 2.898s |
| miniz_probe_compressed_size 6 | 2152 | 2152 | 0.045s | 2152 | 0.004s | 2152 | 2.426s |
| miniz_probe_crc32 | 2035028898 | 2035028898 | 0.040s | 2035028898 | 0.003s | 2035028898 | 1.956s |
| miniz_probe_adler32 | 1263729890 | 1263729890 | 0.040s | 1263729890 | 0.003s | 1263729890 | 1.974s |
| miniz_probe_fold_hash | 828487727 | 828487727 | 0.040s | 828487727 | 0.002s | 828487727 | 2.032s |
| miniz_full_hash 6 | -2109846306 | -2109846306 | 0.058s | -2109846306 | 0.008s | -2109846306 | 2.785s |
| miniz_full_num_files 6 | 3 | 3 | 0.060s | 3 | 0.010s | 3 | 2.669s |
| miniz_full_archive_size 6 | 3200 | 3200 | 0.050s | 3200 | 0.009s | 3200 | 2.710s |
| miniz_full_locate_mix 6 | 258 | 258 | 0.056s | 258 | 0.009s | 258 | 2.758s |
| miniz_full_extract_hash 6 | 1129688585 | 1129688585 | 0.058s | 1129688585 | 0.009s | 1129688585 | 2.652s |
| miniz_full_validate 6 | 1 | 1 | 0.058s | 1 | 0.009s | 1 | 2.726s |
| miniz_file_hash 6 | -138697996 | -138697996 | 0.068s | -138697996 | 0.017s | -138697996 | 2.963s |
| miniz_file_num_files 6 | 4 | 4 | 0.063s | 4 | 0.013s | 4 | 2.923s |
| miniz_file_archive_size 6 | 3473 | 3473 | 0.065s | 3473 | 0.013s | 3473 | 2.957s |
| miniz_file_extract_hash 6 | 1747784103 | 1747784103 | 0.072s | 1747784103 | 0.017s | 1747784103 | 2.918s |
| miniz_file_in_place 6 | 1 | 1 | 0.068s | 1 | 0.015s | 1 | 2.877s |
| lodepng_roundtrip 0 | -1680879972 | -1680879972 | 0.087s | -1680879972 | 0.016s | -1680879972 | 3.858s |
| lodepng_encoded_size 0 | 3870 | 3870 | 0.085s | 3870 | 0.014s | 3870 | 3.412s |
| lodepng_decode_hash 0 | -2110661857 | -2110661857 | 0.084s | -2110661857 | 0.015s | -2110661857 | 4.034s |
| lodepng_input_hash 0 | -2110663679 | -2110663679 | 0.096s | -2110663679 | 0.007s | -2110663679 | 2.293s |
| lodepng_png_hash 0 | 79205344 | 79205344 | 0.097s | 79205344 | 0.014s | 79205344 | 4.010s |
| lodepng_roundtrip 1 | -998874337 | -998874337 | 0.096s | -998874337 | 0.026s | -998874337 | 5.201s |
| lodepng_encoded_size 1 | 6518 | 6518 | 0.102s | 6518 | 0.017s | 6518 | 4.697s |
| lodepng_decode_hash 1 | 496467531 | 496467531 | 0.099s | 496467531 | 0.022s | 496467531 | 4.876s |
| lodepng_input_hash 1 | 496461629 | 496461629 | 0.086s | 496461629 | 0.006s | 496461629 | 1.931s |
| lodepng_png_hash 1 | -1526580224 | -1526580224 | 0.088s | -1526580224 | 0.016s | -1526580224 | 4.049s |
| chipmunk_hash_scene 60 | -1855749543 | -1855749543 | 0.052s | -1855749543 | 0.010s | -1855749543 | 2.995s |
| chipmunk_hash_scene 600 | 792478063 | 792478063 | 0.056s | 792478063 | 0.071s | 792478063 | 10.920s |
| chipmunk_variant 600 | -455480843 | -455480843 | 0.060s | -455480843 | 0.087s | -455480843 | 13.073s |
| chipmunk_probe_x 0 600 | -1071644672 | -1071644672 | 0.058s | -1071644672 | 0.071s | -1071644672 | 10.658s |
| chipmunk_probe_y 1 600 | -216627709 | -216627709 | 0.058s | -216627709 | 0.077s | -216627709 | 10.744s |
| chipmunk_probe_angle 2 600 | -343754584 | -343754584 | 0.057s | -343754584 | 0.071s | -343754584 | 10.709s |
| secret_expected_length | 14 | 14 | 0.036s | 14 | 0.003s | 14 | 1.871s |
| secret_expected_crc32 | -197449106 | -197449106 | 0.039s | -197449106 | 0.003s | -197449106 | 1.912s |
| profile_memory_walk 400 | n/a | *-570043616* | 0.056s | *-570043616* | 0.008s | *-570043616* | 3.242s |
| profile_math_shim 400 | n/a | *1383664881* | 0.054s | *1383664881* | 0.004s | *1383664881* | 1.985s |
| profile_branch_state 400 | n/a | *1353395855* | 0.054s | *1353395855* | 0.004s | *1353395855* | 2.085s |
| profile_space_freefall 120 | n/a | *-1909426722* | 0.055s | *-1909426722* | 0.006s | *-1909426722* | 2.297s |
| profile_space_collision 120 | n/a | *-2022626456* | 0.060s | *-2022626456* | 0.015s | *-2022626456* | 3.674s |
| profile_space_full 120 | n/a | *1338244701* | 0.058s | *1338244701* | 0.023s | *1338244701* | 3.776s |
| h264mp4_decode_hash 8 | -419184337 | -419184337 | 0.141s | -419184337 | 0.031s | -419184337 | 3.722s |
| h264mp4_width | 96 | 96 | 0.123s | 96 | 0.015s | 96 | 2.383s |
| h264mp4_height | 64 | 64 | 0.123s | 64 | 0.015s | 64 | 2.384s |
| h264mp4_frame_count 8 | 8 | 8 | 0.125s | 8 | 0.025s | 8 | 3.712s |
| h264mp4_first_frame | -53578803 | -53578803 | 0.120s | -53578803 | 0.015s | -53578803 | 2.383s |
| h264mp4_last_frame 8 | 131893473 | 131893473 | 0.126s | 131893473 | 0.026s | 131893473 | 3.707s |
| plmpeg_decode_hash 8 | -1675151828 | -1675151828 | 0.069s | -1675151828 | 0.031s | -1675151828 | 5.027s |
| plmpeg_width | 96 | 96 | 0.064s | 96 | 0.020s | 96 | 2.401s |
| plmpeg_height | 64 | 64 | 0.068s | 64 | 0.020s | 64 | 2.410s |
| plmpeg_frame_count 8 | 8 | 8 | 0.068s | 8 | 0.031s | 8 | 5.112s |
| plmpeg_first_frame | 1251253572 | 1251253572 | 0.066s | 1251253572 | 0.020s | 1251253572 | 2.421s |
| plmpeg_last_frame 8 | 1609960924 | 1609960924 | 0.067s | 1609960924 | 0.032s | 1609960924 | 4.972s |
| plmpeg_stream_decode_hash 8 | -1675151828 | -1675151828 | 0.032s | -1675151828 | 0.032s | -1675151828 | 5.009s |
| plmpeg_stream_width | 96 | 96 | 0.032s | 96 | 0.020s | 96 | 2.396s |
| plmpeg_stream_height | 64 | 64 | 0.031s | 64 | 0.020s | 64 | 2.499s |
| plmpeg_stream_frame_count 8 | 8 | 8 | 0.032s | 8 | 0.031s | 8 | 5.104s |
| plmpeg_stream_first_frame | 1251253572 | 1251253572 | 0.031s | 1251253572 | 0.020s | 1251253572 | 2.393s |
| plmpeg_stream_last_frame 8 | 1609960924 | 1609960924 | 0.034s | 1609960924 | 0.031s | 1609960924 | 5.087s |
| libjpeg_decode_hash | 950757193 | 950757193 | 0.246s | 950757193 | 0.018s | 950757193 | 3.397s |
| libjpeg_width | 227 | 227 | 0.243s | 227 | 0.017s | 227 | 3.254s |
| libjpeg_height | 149 | 149 | 0.251s | 149 | 0.017s | 149 | 3.242s |
| libjpeg_components | 3 | 3 | 0.244s | 3 | 0.017s | 3 | 3.198s |
| libjpeg_input_hash | 1227945443 | 1227945443 | 0.243s | 1227945443 | 0.011s | 1227945443 | 1.886s |
| libjpeg_rgb_size | 101469 | 101469 | 0.237s | 101469 | 0.017s | 101469 | 3.163s |
| mjpeg_decode_hash 12 | -598443464 | -598443464 | 0.242s | -598443464 | 0.030s | -598443464 | 5.521s |
| mjpeg_width | 96 | 96 | 0.248s | 96 | 0.013s | 96 | 2.283s |
| mjpeg_height | 64 | 64 | 0.238s | 64 | 0.013s | 64 | 2.304s |
| mjpeg_components | 3 | 3 | 0.240s | 3 | 0.013s | 3 | 2.282s |
| mjpeg_frame_count 12 | 12 | 12 | 0.239s | 12 | 0.027s | 12 | 5.497s |
| mjpeg_first_frame | -924446984 | -924446984 | 0.237s | -924446984 | 0.014s | -924446984 | 2.309s |
| mjpeg_last_frame 12 | 1556833302 | 1556833302 | 0.237s | 1556833302 | 0.028s | 1556833302 | 5.623s |
| mjpeg_input_hash | 755618084 | 755618084 | 0.239s | 755618084 | 0.010s | 755618084 | 1.946s |
| binjgb_decode_hash 16 | -1323964910 | -1323964910 | 0.088s | -1323964910 | 0.159s | -1323964910 | 32.542s |
| binjgb_width | 160 | 160 | 0.072s | 160 | 0.018s | 160 | 1.896s |
| binjgb_height | 144 | 144 | 0.073s | 144 | 0.018s | 144 | 1.930s |
| binjgb_frame_count 16 | 16 | 16 | 0.091s | 16 | 0.160s | 16 | 32.579s |
| binjgb_first_frame | 1015431621 | 1015431621 | 0.081s | 1015431621 | 0.028s | 1015431621 | 3.847s |
| binjgb_last_frame 16 | 838717591 | 838717591 | 0.090s | 838717591 | 0.164s | 838717591 | 32.272s |
| builder_case_count | 3 | 3 | 0.117s | 3 | 0.005s | 3 | 1.899s |
| builder_c0_code_hash | n/a | *1183502082* | 0.119s | *1183502082* | 0.007s | *1183502082* | 2.068s |
| builder_c0_run_hash | n/a | *1193852273* | 0.122s | *1193852273* | 0.006s | *1193852273* | 2.077s |
| builder_c1_code_hash | n/a | *-1661873899* | 0.120s | *-1661873899* | 0.007s | *-1661873899* | 2.071s |
| builder_c1_run_hash | n/a | *-472748772* | 0.117s | *-472748772* | 0.006s | *-472748772* | 2.067s |
| builder_c2_code_hash | n/a | *-1794148870* | 0.108s | *-1794148870* | 0.008s | *-1794148870* | 2.139s |
| builder_c2_run_hash | n/a | *693920941* | 0.121s | *693920941* | 0.007s | *693920941* | 2.109s |

## Totals

| runtime | total time | baseline matches | no baseline | time vs wasm3 (C) |
| --- | ---: | ---: | ---: | ---: |
| wasmtime | 8.765s | 86/86 | 12 | 4.3x |
| wasm3 (original C) | 2.050s | 86/86 | 12 | 1.0x |
| wasm3das | 6m56.8s | 86/86 | 12 | 203x |

## Skipped entries

- `test_pure/render_frame 0.0` — runs ~400M float iterations; interpreter-in-interpreter would take hours
- `i64 probe_hash_i64_div_*_0/1` — debug probes, need i64 args, no documented baselines
- `host-adapter paths (gltf_rs, cgltf, wasm3, archive-secret extract, lodepng/plmpeg-stream host, lodepng_diag)` — need a Daslang memory-adapter driver, out of scope here
- `real-world-smollm2` — no wasm module built (upstream blocker on tensor callbacks)

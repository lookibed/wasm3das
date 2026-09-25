| test | export | args | result | baseline | load ms | call ms | total ms | match |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| fixtures/add | add | 1 2 | 3 | 3 | 0.7 | 0.0 | 0.7 | ok |
| hash_loop 123456789 200000 | hash_loop | 123456789 200000 | -1767246609 | -1767246609 | 0.9 | 533.3 | 534.1 | ok |
| hash_loop 1 65536 | hash_loop | 1 65536 | 1645510779 | 1645510779 | 0.8 | 181.6 | 182.5 | ok |
| hash_f32 2048 | hash_f32 | 2048 | 206320613 | 206320613 | 1.1 | 12.2 | 13.4 | ok |
| hash_f64 2048 | hash_f64 | 2048 | -736305322 | -736305322 | 1.2 | 13.9 | 15.0 | ok |
| hash_i64_mix 512 | hash_i64_mix | 512 | -921783428 | -921783428 | 2.7 | 2.2 | 4.8 | ok |
| hash_i64_div 512 | hash_i64_div | 512 | -1398093681 | -1398093681 | 1.1 | 3.3 | 4.4 | ok |
| probe_div_s64 | probe_div_s64 |  | 674596155 | 674596155 | 0.8 | 0.0 | 0.8 | ok |
| probe_rem_s64 | probe_rem_s64 |  | 0 | 0 | 0.9 | 0.0 | 0.9 | ok |
| probe_div_u64 | probe_div_u64 |  | 1290282190 | 1290282190 | 0.7 | 0.0 | 0.7 | ok |
| probe_rem_u64 | probe_rem_u64 |  | 0 | 0 | 0.7 | 0.0 | 0.7 | ok |
| tinyexpr_hash 256 | tinyexpr_hash | 256 | 141480662 | 141480662 | 2.3 | 106.8 | 109.1 | ok |
| tinyexpr_error_code | tinyexpr_error_code |  | 6 | 6 | 1.6 | 6.8 | 8.3 | ok |
| miniz_roundtrip_hash 6 | miniz_roundtrip_hash | 6 | 58679047 | 58679047 | 2.4 | 342.8 | 345.2 | ok |
| miniz_probe_compressed_size 6 | miniz_probe_compressed_size | 6 | 2152 | 2152 | 1.8 | 254.8 | 256.6 | ok |
| miniz_probe_crc32 | miniz_probe_crc32 |  | 2035028898 | 2035028898 | 1.9 | 38.9 | 40.8 | ok |
| miniz_probe_adler32 | miniz_probe_adler32 |  | 1263729890 | 1263729890 | 2.6 | 32.7 | 35.3 | ok |
| miniz_probe_fold_hash | miniz_probe_fold_hash |  | 828487727 | 828487727 | 2.0 | 33.3 | 35.3 | ok |
| miniz_full_hash 6 | miniz_full_hash | 6 | -2109846306 | -2109846306 | 3.0 | 466.2 | 469.2 | ok |
| miniz_full_num_files 6 | miniz_full_probe_num_files | 6 | 3 | 3 | 3.4 | 463.4 | 466.8 | ok |
| miniz_full_archive_size 6 | miniz_full_probe_archive_size | 6 | 3200 | 3200 | 3.4 | 462.9 | 466.3 | ok |
| miniz_full_locate_mix 6 | miniz_full_probe_locate_mix | 6 | 258 | 258 | 3.1 | 466.5 | 469.6 | ok |
| miniz_full_extract_hash 6 | miniz_full_probe_extract_hash | 6 | 1129688585 | 1129688585 | 3.5 | 461.7 | 465.2 | ok |
| miniz_full_validate 6 | miniz_full_probe_validate | 6 | 1 | 1 | 3.2 | 471.9 | 475.2 | ok |
| miniz_file_hash 6 | miniz_file_hash | 6 | -138697996 | -138697996 | 7.6 | 605.3 | 612.9 | ok |
| miniz_file_num_files 6 | miniz_file_probe_num_files | 6 | 4 | 4 | 6.4 | 605.8 | 612.2 | ok |
| miniz_file_archive_size 6 | miniz_file_probe_archive_size | 6 | 3473 | 3473 | 5.5 | 603.2 | 608.7 | ok |
| miniz_file_extract_hash 6 | miniz_file_probe_extract_hash | 6 | 1747784103 | 1747784103 | 5.3 | 595.0 | 600.3 | ok |
| miniz_file_in_place 6 | miniz_file_probe_in_place | 6 | 1 | 1 | 5.4 | 604.0 | 609.5 | ok |
| lodepng_roundtrip 0 | lodepng_roundtrip_hash | 0 | -1680879972 | -1680879972 | 6.6 | 1056.3 | 1062.9 | ok |
| lodepng_encoded_size 0 | lodepng_probe_encoded_size | 0 | 3870 | 3870 | 6.9 | 896.7 | 903.6 | ok |
| lodepng_decode_hash 0 | lodepng_probe_decode_hash | 0 | -2110661857 | -2110661857 | 6.6 | 1049.6 | 1056.2 | ok |
| lodepng_input_hash 0 | lodepng_probe_input_hash | 0 | -2110663679 | -2110663679 | 7.4 | 11.6 | 19.0 | ok |
| lodepng_png_hash 0 | lodepng_probe_png_hash | 0 | 79205344 | 79205344 | 7.7 | 897.4 | 905.1 | ok |
| lodepng_roundtrip 1 | lodepng_roundtrip_hash | 1 | -998874337 | -998874337 | 10.0 | 1513.7 | 1523.7 | ok |
| lodepng_encoded_size 1 | lodepng_probe_encoded_size | 1 | 6518 | 6518 | 6.4 | 1284.4 | 1290.8 | ok |
| lodepng_decode_hash 1 | lodepng_probe_decode_hash | 1 | 496467531 | 496467531 | 6.6 | 1523.6 | 1530.2 | ok |
| lodepng_input_hash 1 | lodepng_probe_input_hash | 1 | 496461629 | 496461629 | 7.6 | 20.1 | 27.8 | ok |
| lodepng_png_hash 1 | lodepng_probe_png_hash | 1 | -1526580224 | -1526580224 | 7.6 | 1314.0 | 1321.6 | ok |
| chipmunk_hash_scene 60 | chipmunk_hash_scene | 60 | -1855749543 | -1855749543 | 3.5 | 638.9 | 642.4 | ok |
| chipmunk_hash_scene 600 | chipmunk_hash_scene | 600 | 792478063 | 792478063 | 3.5 | 6302.7 | 6306.3 | ok |
| chipmunk_variant 600 | chipmunk_hash_scene_variant | 600 | -455480843 | -455480843 | 3.4 | 8110.1 | 8113.5 | ok |
| chipmunk_probe_x 0 600 | chipmunk_probe_body_x | 0 600 | -1071644672 | -1071644672 | 3.4 | 6310.4 | 6313.8 | ok |
| chipmunk_probe_y 1 600 | chipmunk_probe_body_y | 1 600 | -216627709 | -216627709 | 3.5 | 6373.7 | 6377.1 | ok |
| chipmunk_probe_angle 2 600 | chipmunk_probe_angle | 2 600 | -343754584 | -343754584 | 3.6 | 6341.7 | 6345.3 | ok |
| secret_expected_length | miniz_secret_expected_length |  | 14 | 14 | 1.4 | 0.0 | 1.5 | ok |
| secret_expected_crc32 | miniz_secret_probe_expected_crc32 |  | -197449106 | -197449106 | 1.6 | 0.7 | 2.3 | ok |
| profile_memory_walk 400 | profile_memory_walk | 400 | -570043616 | None | 4.4 | 816.5 | 820.9 | n/a |
| profile_math_shim 400 | profile_math_shim | 400 | 1383664881 | None | 4.3 | 60.4 | 64.6 | n/a |
| profile_branch_state 400 | profile_branch_state | 400 | 1353395855 | None | 4.8 | 107.5 | 112.3 | n/a |
| profile_space_freefall 120 | profile_space_freefall | 120 | -1909426722 | None | 3.7 | 226.5 | 230.2 | n/a |
| profile_space_collision 120 | profile_space_collision | 120 | -2022626456 | None | 4.5 | 1209.5 | 1214.1 | n/a |
| profile_space_full 120 | profile_space_full | 120 | 1338244701 | None | 3.9 | 1222.4 | 1226.3 | n/a |
| h264mp4_decode_hash 8 | h264mp4_decode_hash | 8 | -419184337 | -419184337 | 7.3 | 1128.4 | 1135.7 | ok |
| h264mp4_width | h264mp4_probe_width |  | 96 | 96 | 7.3 | 330.6 | 337.9 | ok |
| h264mp4_height | h264mp4_probe_height |  | 64 | 64 | 7.3 | 329.2 | 336.5 | ok |
| h264mp4_frame_count 8 | h264mp4_probe_frame_count | 8 | 8 | 8 | 7.2 | 1140.2 | 1147.5 | ok |
| h264mp4_first_frame | h264mp4_probe_first_frame_hash |  | -53578803 | -53578803 | 7.8 | 334.9 | 342.7 | ok |
| h264mp4_last_frame 8 | h264mp4_probe_last_frame_hash | 8 | 131893473 | 131893473 | 7.4 | 1133.0 | 1140.4 | ok |
| plmpeg_decode_hash 8 | plmpeg_decode_hash | 8 | -1675151828 | -1675151828 | 8.7 | 1920.6 | 1929.2 | ok |
| plmpeg_width | plmpeg_probe_width |  | 96 | 96 | 8.4 | 317.4 | 325.8 | ok |
| plmpeg_height | plmpeg_probe_height |  | 64 | 64 | 13.0 | 313.9 | 326.9 | ok |
| plmpeg_frame_count 8 | plmpeg_probe_frame_count | 8 | 8 | 8 | 9.8 | 1908.5 | 1918.3 | ok |
| plmpeg_first_frame | plmpeg_probe_first_frame_hash |  | 1251253572 | 1251253572 | 8.9 | 315.5 | 324.4 | ok |
| plmpeg_last_frame 8 | plmpeg_probe_last_frame_hash | 8 | 1609960924 | 1609960924 | 8.9 | 1938.9 | 1947.9 | ok |
| plmpeg_stream_decode_hash 8 | plmpeg_decode_hash | 8 | -1675151828 | -1675151828 | 7.8 | 1915.1 | 1922.9 | ok |
| plmpeg_stream_width | plmpeg_probe_width |  | 96 | 96 | 14.1 | 317.7 | 331.8 | ok |
| plmpeg_stream_height | plmpeg_probe_height |  | 64 | 64 | 7.4 | 314.3 | 321.8 | ok |
| plmpeg_stream_frame_count 8 | plmpeg_probe_frame_count | 8 | 8 | 8 | 7.3 | 1933.0 | 1940.3 | ok |
| plmpeg_stream_first_frame | plmpeg_probe_first_frame_hash |  | 1251253572 | 1251253572 | 8.6 | 316.7 | 325.3 | ok |
| plmpeg_stream_last_frame 8 | plmpeg_probe_last_frame_hash | 8 | 1609960924 | 1609960924 | 7.2 | 1966.3 | 1973.6 | ok |
| libjpeg_decode_hash | libjpeg_turbo_decode_hash |  | 950757193 | 950757193 | 18.5 | 975.2 | 993.7 | ok |
| libjpeg_width | libjpeg_turbo_probe_width |  | 227 | 227 | 16.2 | 818.6 | 834.8 | ok |
| libjpeg_height | libjpeg_turbo_probe_height |  | 149 | 149 | 19.3 | 810.5 | 829.8 | ok |
| libjpeg_components | libjpeg_turbo_probe_components |  | 3 | 3 | 18.4 | 817.0 | 835.4 | ok |
| libjpeg_input_hash | libjpeg_turbo_probe_input_hash |  | 1227945443 | 1227945443 | 16.0 | 5.7 | 21.8 | ok |
| libjpeg_rgb_size | libjpeg_turbo_probe_rgb_size |  | 101469 | 101469 | 15.8 | 817.7 | 833.6 | ok |
| mjpeg_decode_hash 12 | libjpeg_turbo_mjpeg_decode_hash | 12 | -598443464 | -598443464 | 16.9 | 2275.2 | 2292.2 | ok |
| mjpeg_width | libjpeg_turbo_mjpeg_probe_width |  | 96 | 96 | 17.1 | 256.4 | 273.6 | ok |
| mjpeg_height | libjpeg_turbo_mjpeg_probe_height |  | 64 | 64 | 16.2 | 251.0 | 267.3 | ok |
| mjpeg_components | libjpeg_turbo_mjpeg_probe_components |  | 3 | 3 | 23.4 | 250.9 | 274.3 | ok |
| mjpeg_frame_count 12 | libjpeg_turbo_mjpeg_probe_frame_count | 12 | 12 | 12 | 16.7 | 2255.8 | 2272.5 | ok |
| mjpeg_first_frame | libjpeg_turbo_mjpeg_probe_first_frame_hash |  | -924446984 | -924446984 | 16.2 | 249.4 | 265.5 | ok |
| mjpeg_last_frame 12 | libjpeg_turbo_mjpeg_probe_last_frame_hash | 12 | 1556833302 | 1556833302 | 16.4 | 2267.1 | 2283.5 | ok |
| mjpeg_input_hash | libjpeg_turbo_mjpeg_probe_input_hash |  | 755618084 | 755618084 | 16.6 | 26.4 | 43.0 | ok |
| binjgb_decode_hash 16 | binjgb_decode_hash | 16 | -1323964910 | -1323964910 | 9.9 | 20123.1 | 20133.0 | ok |
| binjgb_width | binjgb_probe_width |  | 160 | 160 | 19.8 | 0.0 | 19.8 | ok |
| binjgb_height | binjgb_probe_height |  | 144 | 144 | 9.3 | 0.0 | 9.4 | ok |
| binjgb_frame_count 16 | binjgb_probe_frame_count | 16 | 16 | 16 | 9.3 | 20372.4 | 20381.7 | ok |
| binjgb_first_frame | binjgb_probe_first_frame_hash |  | 1015431621 | 1015431621 | 9.9 | 1238.2 | 1248.1 | ok |
| binjgb_last_frame 16 | binjgb_probe_last_frame_hash | 16 | 838717591 | 838717591 | 10.5 | 20255.5 | 20266.0 | ok |
| builder_case_count | builder_case_count |  | 3 | 3 | 5.3 | 0.0 | 5.3 | ok |
| builder_c0_code_hash | builder_probe_code_hash | 0 | 1183502082 | None | 6.6 | 118.0 | 124.6 | n/a |
| builder_c0_run_hash | builder_run_case_hash | 0 | 1193852273 | None | 6.7 | 127.5 | 134.3 | n/a |
| builder_c1_code_hash | builder_probe_code_hash | 1 | -1661873899 | None | 5.7 | 141.1 | 146.7 | n/a |
| builder_c1_run_hash | builder_run_case_hash | 1 | -472748772 | None | 6.4 | 132.3 | 138.7 | n/a |
| builder_c2_code_hash | builder_probe_code_hash | 2 | -1794148870 | None | 5.9 | 147.0 | 152.8 | n/a |
| builder_c2_run_hash | builder_run_case_hash | 2 | 693920941 | None | 6.9 | 153.1 | 160.0 | n/a |

#!/usr/bin/env python3
"""Spider manual-fixture parity + timing harness.

Runs every scalar (non host-adapter) fixture export through four runtimes:
  wasmtime   (Windows default: D:/Backups/wasmtime/wasmtime-v24.0.1/wasmtime.exe;
              elsewhere: <repo>/tools/bin/wasmtime)
  wasm3      (original C; Windows: wasm3-original-win-x64.exe in the bundle;
              elsewhere: <repo>/tools/bin/wasm3 built from wasm3c/)
  das        (wasm3das, interpreted: wasm3.cmd in the bundle, or
              <repo>/scripts/wasm3)
  jit        (wasm3das, LLVM JIT: the very same front end run with
              WASM3DAS_JIT=1 and DASLANG pointed at a JIT-enabled daslang,
              by default <repo>/tmp/daslang-jit/bin/daslang.  The JIT
              compiles the port on first use into ./.jitted_scripts, so the
              first ever run is much slower than the cached ones.)

Each command is timed with the full wall clock from process spawn to
complete output (subprocess.run + perf_counter, stdout+stderr captured).

Values are compared as signed i32 against the wasmtime baseline recorded
in the fixture READMEs.  The console prints, per runtime, the returned
value, the full time and the match; the Markdown report prints one row per
fixture with the full time of every runtime, marking a cell
`**✗ <result>**` when that runtime disagrees with the baseline or fails,
plus the two slowdown ratios of wasm3das against wasmtime and against C.

The fixture directories, this script and the Markdown report it writes
(tests/manual/fixture_report.md) live under tests/manual/; the automated
dastest suite the quality gate runs is tests/integration/ and is untouched
by this harness.  The console keeps the fixed-width text layout; only the
saved report is Markdown.

Usage, from the repository root:
  python3 tests/manual/run_fixtures.py [--filter substr]
                                       [--runtimes wasmtime,wasm3,das,jit]
                                       [--slow]

Paths can be overridden via env: WASMTIME, WASM3C, WASM3DAS, DASLANG_JIT.
"""
import argparse
import datetime
import os
import platform
import subprocess
import sys
import time
import zlib

MANUAL = os.path.dirname(os.path.abspath(__file__))
# MANUAL is tests/manual/, so two levels up is the repository root (in the
# Windows bundle layout the same two levels reach the bundle root).
BUNDLE_ROOT = os.path.dirname(os.path.dirname(MANUAL))
REPO_ROOT = BUNDLE_ROOT
REPORT_PATH = os.path.join(MANUAL, "fixture_report.md")

if os.name == "nt":
    WASMTIME = os.environ.get("WASMTIME", r"D:\Backups\wasmtime\wasmtime-v24.0.1\wasmtime.exe")
    WASM3C = os.environ.get("WASM3C", os.path.join(BUNDLE_ROOT, "wasm3-original-win-x64.exe"))
    WASM3DAS = os.environ.get("WASM3DAS", os.path.join(BUNDLE_ROOT, "wasm3.cmd"))
else:
    # A repository checkout: tools/ holds the locally installed engines
    # (README "Install and run"), scripts/wasm3 the front end of the port.
    WASMTIME = os.environ.get("WASMTIME", os.path.join(REPO_ROOT, "tools", "bin", "wasmtime"))
    WASM3C = os.environ.get("WASM3C", os.path.join(REPO_ROOT, "tools", "bin", "wasm3"))
    WASM3DAS = os.environ.get("WASM3DAS", os.path.join(REPO_ROOT, "scripts", "wasm3"))

# The JIT runtime drives the same scripts/wasm3 front end, only with a
# JIT-enabled daslang: the pinned gate toolchain is built without LLVM.
DASLANG_JIT = os.environ.get(
    "DASLANG_JIT", os.path.join(REPO_ROOT, "tmp", "daslang-jit", "bin", "daslang"))


def gen(fixture: str) -> str:
    return os.path.join(MANUAL, fixture, "generated")


def signed_crc32(data: bytes) -> int:
    v = zlib.crc32(data)
    return v - 2**32 if v >= 2**31 else v


SECRET = b"Hi Bebra 2026!"

# (test name, wasm path, function, args, wasmtime baseline or None, timeout)
T = [
    # ---- T0 smoke ----
    ("fixtures/add", os.path.join(MANUAL, "fixtures", "test.wasm"), "add", ["1", "2"], 3, 600),
    # ---- T1 micro-benches ----
    ("hash_loop 123456789 200000", gen("hash-compare") + r"\hash_loop.wasm", "hash_loop", ["123456789", "200000"], -1767246609, 900),
    ("hash_loop 1 65536", gen("hash-compare") + r"\hash_loop.wasm", "hash_loop", ["1", "65536"], 1645510779, 900),
    ("hash_f32 2048", gen("float-compare") + r"\float_hash.wasm", "hash_f32", ["2048"], 206320613, 900),
    ("hash_f64 2048", gen("float-compare") + r"\float_hash.wasm", "hash_f64", ["2048"], -736305322, 900),
    ("hash_i64_mix 512", gen("i64-compare") + r"\i64_hash.wasm", "hash_i64_mix", ["512"], -921783428, 900),
    ("hash_i64_div 512", gen("i64-compare") + r"\i64_hash.wasm", "hash_i64_div", ["512"], -1398093681, 900),
    ("probe_div_s64", gen("i64-compare") + r"\i64_hash.wasm", "probe_div_s64", [], 674596155, 900),
    ("probe_rem_s64", gen("i64-compare") + r"\i64_hash.wasm", "probe_rem_s64", [], 0, 900),
    ("probe_div_u64", gen("i64-compare") + r"\i64_hash.wasm", "probe_div_u64", [], 1290282190, 900),
    ("probe_rem_u64", gen("i64-compare") + r"\i64_hash.wasm", "probe_rem_u64", [], 0, 900),
    # ---- T2 self-contained parity ----
    ("tinyexpr_hash 256", gen("real-world-tinyexpr") + r"\tinyexpr.wasm", "tinyexpr_hash", ["256"], 141480662, 900),
    ("tinyexpr_error_code", gen("real-world-tinyexpr") + r"\tinyexpr.wasm", "tinyexpr_error_code", [], 6, 900),
    ("miniz_roundtrip_hash 6", gen("real-world-miniz") + r"\miniz.wasm", "miniz_roundtrip_hash", ["6"], 58679047, 900),
    ("miniz_probe_compressed_size 6", gen("real-world-miniz") + r"\miniz.wasm", "miniz_probe_compressed_size", ["6"], 2152, 900),
    ("miniz_probe_crc32", gen("real-world-miniz") + r"\miniz.wasm", "miniz_probe_crc32", [], 2035028898, 900),
    ("miniz_probe_adler32", gen("real-world-miniz") + r"\miniz.wasm", "miniz_probe_adler32", [], 1263729890, 900),
    ("miniz_probe_fold_hash", gen("real-world-miniz") + r"\miniz.wasm", "miniz_probe_fold_hash", [], 828487727, 900),
    ("miniz_full_hash 6", gen("real-world-miniz-full") + r"\miniz_full.wasm", "miniz_full_hash", ["6"], -2109846306, 900),
    ("miniz_full_num_files 6", gen("real-world-miniz-full") + r"\miniz_full.wasm", "miniz_full_probe_num_files", ["6"], 3, 900),
    ("miniz_full_archive_size 6", gen("real-world-miniz-full") + r"\miniz_full.wasm", "miniz_full_probe_archive_size", ["6"], 3200, 900),
    ("miniz_full_locate_mix 6", gen("real-world-miniz-full") + r"\miniz_full.wasm", "miniz_full_probe_locate_mix", ["6"], 258, 900),
    ("miniz_full_extract_hash 6", gen("real-world-miniz-full") + r"\miniz_full.wasm", "miniz_full_probe_extract_hash", ["6"], 1129688585, 900),
    ("miniz_full_validate 6", gen("real-world-miniz-full") + r"\miniz_full.wasm", "miniz_full_probe_validate", ["6"], 1, 900),
    ("miniz_file_hash 6", gen("real-world-miniz-file") + r"\miniz_file.wasm", "miniz_file_hash", ["6"], -138697996, 900),
    ("miniz_file_num_files 6", gen("real-world-miniz-file") + r"\miniz_file.wasm", "miniz_file_probe_num_files", ["6"], 4, 900),
    ("miniz_file_archive_size 6", gen("real-world-miniz-file") + r"\miniz_file.wasm", "miniz_file_probe_archive_size", ["6"], 3473, 900),
    ("miniz_file_extract_hash 6", gen("real-world-miniz-file") + r"\miniz_file.wasm", "miniz_file_probe_extract_hash", ["6"], 1747784103, 900),
    ("miniz_file_in_place 6", gen("real-world-miniz-file") + r"\miniz_file.wasm", "miniz_file_probe_in_place", ["6"], 1, 900),
    ("lodepng_roundtrip 0", gen("real-world-lodepng") + r"\lodepng.wasm", "lodepng_roundtrip_hash", ["0"], -1680879972, 900),
    ("lodepng_encoded_size 0", gen("real-world-lodepng") + r"\lodepng.wasm", "lodepng_probe_encoded_size", ["0"], 3870, 900),
    ("lodepng_decode_hash 0", gen("real-world-lodepng") + r"\lodepng.wasm", "lodepng_probe_decode_hash", ["0"], -2110661857, 900),
    ("lodepng_input_hash 0", gen("real-world-lodepng") + r"\lodepng.wasm", "lodepng_probe_input_hash", ["0"], -2110663679, 900),
    ("lodepng_png_hash 0", gen("real-world-lodepng") + r"\lodepng.wasm", "lodepng_probe_png_hash", ["0"], 79205344, 900),
    ("lodepng_roundtrip 1", gen("real-world-lodepng") + r"\lodepng.wasm", "lodepng_roundtrip_hash", ["1"], -998874337, 900),
    ("lodepng_encoded_size 1", gen("real-world-lodepng") + r"\lodepng.wasm", "lodepng_probe_encoded_size", ["1"], 6518, 900),
    ("lodepng_decode_hash 1", gen("real-world-lodepng") + r"\lodepng.wasm", "lodepng_probe_decode_hash", ["1"], 496467531, 900),
    ("lodepng_input_hash 1", gen("real-world-lodepng") + r"\lodepng.wasm", "lodepng_probe_input_hash", ["1"], 496461629, 900),
    ("lodepng_png_hash 1", gen("real-world-lodepng") + r"\lodepng.wasm", "lodepng_probe_png_hash", ["1"], -1526580224, 900),
    ("chipmunk_hash_scene 60", gen("real-world-chipmunk") + r"\chipmunk.wasm", "chipmunk_hash_scene", ["60"], -1855749543, 900),
    ("chipmunk_hash_scene 600", gen("real-world-chipmunk") + r"\chipmunk.wasm", "chipmunk_hash_scene", ["600"], 792478063, 900),
    ("chipmunk_variant 600", gen("real-world-chipmunk") + r"\chipmunk.wasm", "chipmunk_hash_scene_variant", ["600"], -455480843, 900),
    ("chipmunk_probe_x 0 600", gen("real-world-chipmunk") + r"\chipmunk.wasm", "chipmunk_probe_body_x", ["0", "600"], -1071644672, 900),
    ("chipmunk_probe_y 1 600", gen("real-world-chipmunk") + r"\chipmunk.wasm", "chipmunk_probe_body_y", ["1", "600"], -216627709, 900),
    ("chipmunk_probe_angle 2 600", gen("real-world-chipmunk") + r"\chipmunk.wasm", "chipmunk_probe_angle", ["2", "600"], -343754584, 900),
    ("secret_expected_length", gen("real-archive-secret") + r"\secret_reader.wasm", "miniz_secret_expected_length", [], len(SECRET), 900),
    ("secret_expected_crc32", gen("real-archive-secret") + r"\secret_reader.wasm", "miniz_secret_probe_expected_crc32", [], signed_crc32(SECRET), 900),
    # ---- T2b profiling classes (no documented baselines) ----
    ("profile_memory_walk 400", gen("chipmunk-profile") + r"\chipmunk_profile.wasm", "profile_memory_walk", ["400"], None, 1200),
    ("profile_math_shim 400", gen("chipmunk-profile") + r"\chipmunk_profile.wasm", "profile_math_shim", ["400"], None, 1200),
    ("profile_branch_state 400", gen("chipmunk-profile") + r"\chipmunk_profile.wasm", "profile_branch_state", ["400"], None, 1200),
    ("profile_space_freefall 120", gen("chipmunk-profile") + r"\chipmunk_profile.wasm", "profile_space_freefall", ["120"], None, 1200),
    ("profile_space_collision 120", gen("chipmunk-profile") + r"\chipmunk_profile.wasm", "profile_space_collision", ["120"], None, 1200),
    ("profile_space_full 120", gen("chipmunk-profile") + r"\chipmunk_profile.wasm", "profile_space_full", ["120"], None, 1200),
    # ---- T3 real-world embedded scalar paths ----
    ("h264mp4_decode_hash 8", gen("real-world-h264bsd-mp4") + r"\h264mp4.wasm", "h264mp4_decode_hash", ["8"], -419184337, 2400),
    ("h264mp4_width", gen("real-world-h264bsd-mp4") + r"\h264mp4.wasm", "h264mp4_probe_width", [], 96, 2400),
    ("h264mp4_height", gen("real-world-h264bsd-mp4") + r"\h264mp4.wasm", "h264mp4_probe_height", [], 64, 2400),
    ("h264mp4_frame_count 8", gen("real-world-h264bsd-mp4") + r"\h264mp4.wasm", "h264mp4_probe_frame_count", ["8"], 8, 2400),
    ("h264mp4_first_frame", gen("real-world-h264bsd-mp4") + r"\h264mp4.wasm", "h264mp4_probe_first_frame_hash", [], -53578803, 2400),
    ("h264mp4_last_frame 8", gen("real-world-h264bsd-mp4") + r"\h264mp4.wasm", "h264mp4_probe_last_frame_hash", ["8"], 131893473, 2400),
    ("plmpeg_decode_hash 8", gen("real-world-plmpeg") + r"\plmpeg.wasm", "plmpeg_decode_hash", ["8"], -1675151828, 2400),
    ("plmpeg_width", gen("real-world-plmpeg") + r"\plmpeg.wasm", "plmpeg_probe_width", [], 96, 2400),
    ("plmpeg_height", gen("real-world-plmpeg") + r"\plmpeg.wasm", "plmpeg_probe_height", [], 64, 2400),
    ("plmpeg_frame_count 8", gen("real-world-plmpeg") + r"\plmpeg.wasm", "plmpeg_probe_frame_count", ["8"], 8, 2400),
    ("plmpeg_first_frame", gen("real-world-plmpeg") + r"\plmpeg.wasm", "plmpeg_probe_first_frame_hash", [], 1251253572, 2400),
    ("plmpeg_last_frame 8", gen("real-world-plmpeg") + r"\plmpeg.wasm", "plmpeg_probe_last_frame_hash", ["8"], 1609960924, 2400),
    ("plmpeg_stream_decode_hash 8", gen("real-world-plmpeg-stream") + r"\plmpeg.wasm", "plmpeg_decode_hash", ["8"], -1675151828, 2400),
    ("plmpeg_stream_width", gen("real-world-plmpeg-stream") + r"\plmpeg.wasm", "plmpeg_probe_width", [], 96, 2400),
    ("plmpeg_stream_height", gen("real-world-plmpeg-stream") + r"\plmpeg.wasm", "plmpeg_probe_height", [], 64, 2400),
    ("plmpeg_stream_frame_count 8", gen("real-world-plmpeg-stream") + r"\plmpeg.wasm", "plmpeg_probe_frame_count", ["8"], 8, 2400),
    ("plmpeg_stream_first_frame", gen("real-world-plmpeg-stream") + r"\plmpeg.wasm", "plmpeg_probe_first_frame_hash", [], 1251253572, 2400),
    ("plmpeg_stream_last_frame 8", gen("real-world-plmpeg-stream") + r"\plmpeg.wasm", "plmpeg_probe_last_frame_hash", ["8"], 1609960924, 2400),
    ("libjpeg_decode_hash", gen("real-world-libjpeg-turbo") + r"\libjpeg_turbo.wasm", "libjpeg_turbo_decode_hash", [], 950757193, 2400),
    ("libjpeg_width", gen("real-world-libjpeg-turbo") + r"\libjpeg_turbo.wasm", "libjpeg_turbo_probe_width", [], 227, 2400),
    ("libjpeg_height", gen("real-world-libjpeg-turbo") + r"\libjpeg_turbo.wasm", "libjpeg_turbo_probe_height", [], 149, 2400),
    ("libjpeg_components", gen("real-world-libjpeg-turbo") + r"\libjpeg_turbo.wasm", "libjpeg_turbo_probe_components", [], 3, 2400),
    ("libjpeg_input_hash", gen("real-world-libjpeg-turbo") + r"\libjpeg_turbo.wasm", "libjpeg_turbo_probe_input_hash", [], 1227945443, 2400),
    ("libjpeg_rgb_size", gen("real-world-libjpeg-turbo") + r"\libjpeg_turbo.wasm", "libjpeg_turbo_probe_rgb_size", [], 101469, 2400),
    ("mjpeg_decode_hash 12", gen("real-world-libjpeg-turbo-mjpeg") + r"\libjpeg_turbo_mjpeg.wasm", "libjpeg_turbo_mjpeg_decode_hash", ["12"], -598443464, 2400),
    ("mjpeg_width", gen("real-world-libjpeg-turbo-mjpeg") + r"\libjpeg_turbo_mjpeg.wasm", "libjpeg_turbo_mjpeg_probe_width", [], 96, 2400),
    ("mjpeg_height", gen("real-world-libjpeg-turbo-mjpeg") + r"\libjpeg_turbo_mjpeg.wasm", "libjpeg_turbo_mjpeg_probe_height", [], 64, 2400),
    ("mjpeg_components", gen("real-world-libjpeg-turbo-mjpeg") + r"\libjpeg_turbo_mjpeg.wasm", "libjpeg_turbo_mjpeg_probe_components", [], 3, 2400),
    ("mjpeg_frame_count 12", gen("real-world-libjpeg-turbo-mjpeg") + r"\libjpeg_turbo_mjpeg.wasm", "libjpeg_turbo_mjpeg_probe_frame_count", ["12"], 12, 2400),
    ("mjpeg_first_frame", gen("real-world-libjpeg-turbo-mjpeg") + r"\libjpeg_turbo_mjpeg.wasm", "libjpeg_turbo_mjpeg_probe_first_frame_hash", [], -924446984, 2400),
    ("mjpeg_last_frame 12", gen("real-world-libjpeg-turbo-mjpeg") + r"\libjpeg_turbo_mjpeg.wasm", "libjpeg_turbo_mjpeg_probe_last_frame_hash", ["12"], 1556833302, 2400),
    ("mjpeg_input_hash", gen("real-world-libjpeg-turbo-mjpeg") + r"\libjpeg_turbo_mjpeg.wasm", "libjpeg_turbo_mjpeg_probe_input_hash", [], 755618084, 2400),
    ("binjgb_decode_hash 16", gen("real-world-binjgb") + r"\binjgb.wasm", "binjgb_decode_hash", ["16"], -1323964910, 2400),
    ("binjgb_width", gen("real-world-binjgb") + r"\binjgb.wasm", "binjgb_probe_width", [], 160, 2400),
    ("binjgb_height", gen("real-world-binjgb") + r"\binjgb.wasm", "binjgb_probe_height", [], 144, 2400),
    ("binjgb_frame_count 16", gen("real-world-binjgb") + r"\binjgb.wasm", "binjgb_probe_frame_count", ["16"], 16, 2400),
    ("binjgb_first_frame", gen("real-world-binjgb") + r"\binjgb.wasm", "binjgb_probe_first_frame_hash", [], 1015431621, 2400),
    ("binjgb_last_frame 16", gen("real-world-binjgb") + r"\binjgb.wasm", "binjgb_probe_last_frame_hash", ["16"], 838717591, 2400),
    # ---- self-hosting builder (only case_count documented) ----
    ("builder_case_count", gen("self-hosting-luanoffi-builder") + r"\self_hosting_luanoffi_builder.wasm", "builder_case_count", [], 3, 1200),
    ("builder_c0_code_hash", gen("self-hosting-luanoffi-builder") + r"\self_hosting_luanoffi_builder.wasm", "builder_probe_code_hash", ["0"], None, 1200),
    ("builder_c0_run_hash", gen("self-hosting-luanoffi-builder") + r"\self_hosting_luanoffi_builder.wasm", "builder_run_case_hash", ["0"], None, 1200),
    ("builder_c1_code_hash", gen("self-hosting-luanoffi-builder") + r"\self_hosting_luanoffi_builder.wasm", "builder_probe_code_hash", ["1"], None, 1200),
    ("builder_c1_run_hash", gen("self-hosting-luanoffi-builder") + r"\self_hosting_luanoffi_builder.wasm", "builder_run_case_hash", ["1"], None, 1200),
    ("builder_c2_code_hash", gen("self-hosting-luanoffi-builder") + r"\self_hosting_luanoffi_builder.wasm", "builder_probe_code_hash", ["2"], None, 1200),
    ("builder_c2_run_hash", gen("self-hosting-luanoffi-builder") + r"\self_hosting_luanoffi_builder.wasm", "builder_run_case_hash", ["2"], None, 1200),
]

# Documented-but-skipped entries
SKIPPED = [
    ("test_pure/render_frame 0.0", "runs ~400M float iterations; interpreter-in-interpreter would take hours"),
    ("i64 probe_hash_i64_div_*_0/1", "debug probes, need i64 args, no documented baselines"),
    ("host-adapter paths (gltf_rs, cgltf, wasm3, archive-secret extract, lodepng/plmpeg-stream host, lodepng_diag)", "need a Daslang memory-adapter driver, out of scope here"),
    ("real-world-smollm2", "no wasm module built (upstream blocker on tensor callbacks)"),
]


# How the arguments of an export read in the report's first column, keyed by
# the exported function name.  `{0}`, `{1}` … are the raw arguments in order.
# A function that is missing here falls back to its raw arguments, and an
# export called without arguments gets no description at all.  Extend the
# table when a fixture with new arguments is added to T.
ARG_DESC = {
    # micro-benches: a seed plus an iteration count, and element counts
    "hash_loop": "seed {0}, {1} итераций",
    "hash_f32": "{0} элементов",
    "hash_f64": "{0} элементов",
    "hash_i64_mix": "{0} элементов",
    "hash_i64_div": "{0} элементов",
    # tinyexpr: how many expressions are parsed and evaluated
    "tinyexpr_hash": "{0} выражений",
    # miniz: the argument is the deflate compression level
    "miniz_roundtrip_hash": "уровень {0}",
    "miniz_probe_compressed_size": "уровень {0}",
    "miniz_full_hash": "уровень {0}",
    "miniz_full_probe_num_files": "уровень {0}",
    "miniz_full_probe_archive_size": "уровень {0}",
    "miniz_full_probe_locate_mix": "уровень {0}",
    "miniz_full_probe_extract_hash": "уровень {0}",
    "miniz_full_probe_validate": "уровень {0}",
    "miniz_file_hash": "уровень {0}",
    "miniz_file_probe_num_files": "уровень {0}",
    "miniz_file_probe_archive_size": "уровень {0}",
    "miniz_file_probe_extract_hash": "уровень {0}",
    "miniz_file_probe_in_place": "уровень {0}",
    # lodepng: the argument selects the built-in picture
    "lodepng_roundtrip_hash": "картинка {0}",
    "lodepng_probe_encoded_size": "картинка {0}",
    "lodepng_probe_decode_hash": "картинка {0}",
    "lodepng_probe_input_hash": "картинка {0}",
    "lodepng_probe_png_hash": "картинка {0}",
    # chipmunk: simulation steps, and a body index for the probes
    "chipmunk_hash_scene": "{0} шагов",
    "chipmunk_hash_scene_variant": "{0} шагов",
    "chipmunk_probe_body_x": "тело {0}, {1} шагов",
    "chipmunk_probe_body_y": "тело {0}, {1} шагов",
    "chipmunk_probe_angle": "тело {0}, {1} шагов",
    # chipmunk profiling classes: space steps versus plain loop iterations
    "profile_memory_walk": "{0} итераций",
    "profile_math_shim": "{0} итераций",
    "profile_branch_state": "{0} итераций",
    "profile_space_freefall": "{0} шагов",
    "profile_space_collision": "{0} шагов",
    "profile_space_full": "{0} шагов",
    # codecs: the argument is a frame count
    "h264mp4_decode_hash": "{0} кадров",
    "h264mp4_probe_frame_count": "{0} кадров",
    "h264mp4_probe_last_frame_hash": "{0} кадров",
    "plmpeg_decode_hash": "{0} кадров",
    "plmpeg_probe_frame_count": "{0} кадров",
    "plmpeg_probe_last_frame_hash": "{0} кадров",
    "libjpeg_turbo_mjpeg_decode_hash": "{0} кадров",
    "libjpeg_turbo_mjpeg_probe_frame_count": "{0} кадров",
    "libjpeg_turbo_mjpeg_probe_last_frame_hash": "{0} кадров",
    "binjgb_decode_hash": "{0} кадров",
    "binjgb_probe_frame_count": "{0} кадров",
    "binjgb_probe_last_frame_hash": "{0} кадров",
    # self-hosting builder: the argument is the case index
    "builder_probe_code_hash": "вариант {0}",
    "builder_run_case_hash": "вариант {0}",
}


def describe(name: str, func: str, args) -> str:
    """The report's first column: the test plus a human reading of its args.

    The backticked name comes from the first word of the entry's name in T,
    not from the export: two fixtures can export the same function (the
    plmpeg and plmpeg-stream modules both have `plmpeg_decode_hash`) and T
    is what tells them apart.  The argument wording still keys on the export.
    """
    short = name.split()[0].rsplit("/", 1)[-1]
    cell = f"`{md(short)}`"
    if not args:
        return cell
    tmpl = ARG_DESC.get(func)
    text = tmpl.format(*args) if tmpl else " ".join(args)
    return f"{cell} {md(text)}"


def fmt_time(s: float) -> str:
    if s >= 60:
        return f"{int(s // 60)}m{s - int(s // 60) * 60:04.1f}s"
    return f"{s:.3f}s"


def parse_int(text: str) -> int:
    for line in reversed(text.splitlines()):
        line = line.strip()
        if not line:
            continue
        if line.startswith("Result:"):
            line = line[len("Result:"):].strip()
        try:
            return int(line)
        except ValueError:
            continue
    raise ValueError(f"no int in {text!r}")


def run_full(cmd, timeout, env=None):
    """Full wall time from spawn to complete output."""
    t0 = time.perf_counter()
    p = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout,
                       env=env)
    dt = time.perf_counter() - t0
    return dt, (p.stdout or "") + (p.stderr or ""), p.returncode


def cmd_wasmtime(wasm, func, args):
    return [WASMTIME, "-C", "cache=n", "--invoke", func, wasm] + args


def cmd_wasm3c(wasm, func, args):
    # original CLI: --func <name> <file> <args...>
    return [WASM3C, "--func", func, wasm] + args


def cmd_das(wasm, func, args):
    # wasm3das CLI: <file> --func <name> <args...>
    return [WASM3DAS, wasm, "--func", func] + args


RUNTIMES = {
    "wasmtime": ("wasmtime", cmd_wasmtime, 300),
    "wasm3": ("wasm3 (original C)", cmd_wasm3c, 600),
    "das": ("wasm3das", cmd_das, 2400),
    "jit": ("wasm3das (JIT)", cmd_das, 2400),
}

# Short labels, used for the report's column headers and its totals table.
RUNTIME_SHORT = {
    "wasmtime": "wasmtime",
    "wasm3": "wasm3 C",
    "das": "wasm3das",
    "jit": "wasm3das(jit)",
}

# Extra environment per runtime, merged over os.environ before the spawn.
# The JIT runtime is scripts/wasm3 with the LLVM path switched on and the
# JIT-enabled compiler selected; everything else inherits the environment.
RUNTIME_ENV = {
    "jit": {"WASM3DAS_JIT": "1", "DASLANG": DASLANG_JIT},
}

# Upper bound on a single run, capping the per-test timeout of T.  The JIT
# gets a short one: on the self-hosting builder fixtures it spins forever
# where the interpreter finishes in two seconds, and a whole run must not
# hang on it — such a process is simply recorded as TIMEOUT.
RUNTIME_CAP = {"jit": 180}

# Executable behind each runtime; used only to print the paths and to ask
# each engine for its version in the report header.
RUNTIME_BIN = {"wasmtime": WASMTIME, "wasm3": WASM3C, "das": WASM3DAS,
               "jit": WASM3DAS}
VERSION_TIMEOUT = 60


def runtime_env(r: str):
    """The environment for runtime `r`, or None to inherit unchanged."""
    extra = RUNTIME_ENV.get(r)
    if not extra:
        return None
    env = dict(os.environ)
    env.update(extra)
    return env


def runtime_version(exe: str, env=None) -> str:
    """`<exe> --version` on one line, empty when it fails or says nothing."""
    try:
        p = subprocess.run([exe, "--version"], capture_output=True, text=True,
                           encoding="utf-8", errors="replace",
                           timeout=VERSION_TIMEOUT, env=env)
    except (OSError, subprocess.SubprocessError):
        return ""
    text = (p.stdout or "") + (p.stderr or "")
    # Drop the JIT's own "[I] LLVM JIT: …" chatter, it says nothing about
    # the engine version and names a per-machine cache file.
    return " / ".join(ln.strip() for ln in text.splitlines()
                      if ln.strip() and not ln.strip().startswith("[I]"))


def machine_name() -> str:
    """CPU model plus the logical CPU count."""
    model = ""
    if sys.platform.startswith("linux"):
        try:
            with open("/proc/cpuinfo", "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("model name"):
                        model = line.split(":", 1)[1].strip()
                        break
        except OSError:
            model = ""
    if not model:
        model = platform.processor() or platform.machine() or "unknown"
    cpus = os.cpu_count()
    return f"{model} ({cpus} logical CPUs)" if cpus else model


def md(text) -> str:
    """A value safe inside a Markdown table cell."""
    return str(text).replace("|", "\\|")


MISSING = "—"


def md_cell(cell) -> str:
    """One runtime cell: the wall time, or the wrong result in its place.

    A runtime that was not run at all is `—`; a runtime that disagrees with
    the documented baseline, errored or timed out shows `**✗ <result>**`
    instead of its time, so correctness stays visible without extra columns.
    """
    if cell is None:
        return MISSING
    val, dt, match = cell
    if match is False:
        return f"**✗ {md(val)}**"
    return fmt_time(dt)


def fmt_ratio(x: float) -> str:
    return f"~{x:.0f}x" if x >= 10 else f"~{x:.1f}x"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--filter", default="", help="run only tests containing this substring")
    ap.add_argument("--runtimes", default="wasmtime,wasm3,das,jit")
    ap.add_argument("--slow", action="store_true",
                    help="also list the skipped entries on the console "
                         "(the report always lists them)")
    ns = ap.parse_args()

    wanted = [r.strip() for r in ns.runtimes.split(",") if r.strip()]
    for r in wanted:
        if r not in RUNTIMES:
            sys.exit(f"unknown runtime {r!r}; known: {', '.join(RUNTIMES)}")
    tests = [t for t in T if ns.filter.lower() in t[0].lower()
             or ns.filter.lower() in (t[2] + " " + " ".join(t[3])).lower()]
    if not tests:
        sys.exit("no tests match the filter")

    # The console keeps the fixed-width layout; the saved report is Markdown
    # and is assembled separately in `doc`.
    def out(s=""):
        print(s)

    out("=" * 148)
    out(f"Spider manual fixtures: {len(tests)} checks x {len(wanted)} runtimes")
    out(f"  wasmtime : {WASMTIME}")
    out(f"  wasm3    : {WASM3C}")
    out(f"  wasm3das : {WASM3DAS}")
    out("=" * 148)

    rows = []
    totals = {r: 0.0 for r in wanted}
    ok_counts = {r: 0 for r in wanted}
    base_counts = {r: 0 for r in wanted}
    err_counts = {r: 0 for r in wanted}

    for name, wasm, func, args, baseline, timeout in tests:
        # The table above spells the module names with a Windows separator;
        # make the path native so the same list runs on Linux and macOS.
        wasm = wasm.replace("\\", os.sep)
        row = {"name": name, "func": func, "args": args, "baseline": baseline}
        for r in wanted:
            label, mkcmd, to = RUNTIMES[r]
            cmd = mkcmd(wasm, func, args)
            # A runtime may cap the per-test timeout (see RUNTIME_CAP).
            deadline = min(timeout, RUNTIME_CAP.get(r, timeout))
            try:
                dt, text, rc = run_full(cmd, deadline, runtime_env(r))
                try:
                    val = parse_int(text)
                except ValueError:
                    val = None
                if val is None or rc != 0:
                    # A failed run is not part of the runtime's total time:
                    # it never produced a result to time.
                    err_counts[r] += 1
                    if baseline is not None:
                        base_counts[r] += 1
                    row[r] = ("ERR", dt, False)
                else:
                    totals[r] += dt
                    if baseline is None:
                        row[r] = (val, dt, None)
                    else:
                        base_counts[r] += 1
                        match = val == baseline
                        row[r] = (val, dt, match)
                        ok_counts[r] += 1 if match else 0
            except subprocess.TimeoutExpired:
                err_counts[r] += 1
                if baseline is not None:
                    base_counts[r] += 1
                row[r] = ("TIMEOUT", float(deadline), False)
        rows.append(row)
        print(f"  ran: {name:44s} das={fmt_time(row['das'][1]):>9s}"
              if "das" in row else "", file=sys.stderr)

    w = 150
    out()
    out("=" * w)
    hdr = f"{'test':<34s} | {'wasmtime baseline':>17s} |"
    for r in wanted:
        hdr += f" {RUNTIMES[r][0][:14]:>14s} {'time':>9s} {'ok':>5s} |"
    out(hdr)
    out("-" * w)
    for row in rows:
        line = f"{row['name'][:34]:<34s} |"
        b = row["baseline"]
        line += f" {str(b) if b is not None else 'n/a':>17s} |"
        for r in wanted:
            val, dt, match = row[r]
            vs = str(val) if not isinstance(val, str) else val
            ms = {True: "true", False: "false", None: "n/a"}[match]
            line += f" {vs[:14]:>14s} {fmt_time(dt):>9s} {ms:>5s} |"
        out(line)
    out("-" * w)
    for r in wanted:
        out(f"{RUNTIMES[r][0][:18]:<20s} total time: {fmt_time(totals[r]):>10s}   "
            f"baseline match: {ok_counts[r]}/{base_counts[r]}   "
            f"(n/a without baseline: {sum(1 for row in rows if row[r][2] is None)})")
    out("=" * w)
    if ns.slow:
        out()
        out("Skipped entries:")
        for n, why in SKIPPED:
            out(f"  - {n:60s} {why}")

    # ---- the Markdown report ----
    # One row per entry of T, in T's order: the export with a human reading
    # of its arguments, the full wall clock of every runtime, and how much
    # slower interpreted wasm3das is than wasmtime and than the C wasm3.
    doc = []
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc.append("# Spider manual fixtures: parity and timing")
    doc.append("")

    def ratio_cell(row, ref):
        """`× к <ref>`: the wasm3das time over the reference runtime's time."""
        if "das" not in wanted or ref not in wanted:
            return MISSING
        mine, theirs = row.get("das"), row.get(ref)
        if not mine or not theirs or theirs[1] <= 0:
            return MISSING
        return fmt_ratio(mine[1] / theirs[1])

    head = "| Тест |"
    sep = "| --- |"
    for r in wanted:
        head += f" {md(RUNTIME_SHORT[r])} |"
        sep += " ---: |"
    head += " × к wasmtime | × к wasm3 C |"
    sep += " ---: | ---: |"
    doc.append(head)
    doc.append(sep)
    for row in rows:
        line = f"| {describe(row['name'], row['func'], row['args'])} |"
        for r in wanted:
            line += f" {md_cell(row.get(r))} |"
        line += f" {ratio_cell(row, 'wasmtime')} | {ratio_cell(row, 'wasm3')} |"
        doc.append(line)

    doc.append("")
    # Correctness without extra columns: a time cell that reads
    # `**✗ …**` is a runtime that disagreed with the documented baseline.
    # The tally is per runtime, so one fragile engine does not hide that the
    # others are clean.
    checked = [row for row in rows if row["baseline"] is not None]
    bad = [(row, r) for row in rows if row["baseline"] is not None
           for r in wanted if row[r][2] is False]
    tally = ", ".join(f"{md(RUNTIME_SHORT[r])} {ok_counts[r]}/{base_counts[r]}"
                      for r in wanted)
    if not bad:
        doc.append(f"Все результаты совпали с baseline ({tally})")
    else:
        doc.append(f"Совпало с baseline: {tally}. Расхождения:")
        doc.append("")
        for row, r in bad:
            doc.append(f"- {describe(row['name'], row['func'], row['args'])}"
                       f" — {md(RUNTIME_SHORT[r])}: {md(row[r][0])}"
                       f" вместо {md(row['baseline'])}")
    no_base = len(rows) - len(checked)
    if no_base:
        doc.append("")
        doc.append(f"Ещё {no_base} строк(и) без документированного baseline"
                   " остаются в таблице, их результат не проверяется.")

    doc.append("")
    doc.append("## Итого")
    doc.append("")
    with_ratio = "wasm3" in wanted and totals.get("wasm3", 0.0) > 0
    doc.append("| runtime | суммарное время | × к wasm3 C |")
    doc.append("| --- | ---: | ---: |")
    for r in wanted:
        # The total covers the rows that produced a result; a run that
        # errored or timed out timed nothing, so it is only counted.
        ratio = fmt_ratio(totals[r] / totals["wasm3"]) if with_ratio else MISSING
        errs = f" ({err_counts[r]} ERR)" if err_counts[r] else ""
        doc.append(f"| {md(RUNTIME_SHORT[r])} | {fmt_time(totals[r])}{errs}"
                   f" | {ratio} |")

    doc.append("")
    doc.append("## Прогон")
    doc.append("")
    doc.append(f"- Date (UTC): {now}")
    doc.append(f"- Machine: {md(machine_name())}")
    doc.append(f"- Platform: {md(platform.platform())}")
    doc.append(f"- Checks: {len(tests)} x {len(wanted)} runtimes")
    doc.append(f"- Invocation: `{' '.join(sys.argv)}`")
    doc.append("")
    doc.append("Runtimes:")
    doc.append("")
    for r in wanted:
        env = runtime_env(r)
        ver = runtime_version(RUNTIME_BIN[r], env)
        cmd = "".join(f"{k}={v} " for k, v in sorted(RUNTIME_ENV.get(r, {}).items()))
        doc.append(f"- {md(RUNTIME_SHORT[r])}: `{md(cmd + RUNTIME_BIN[r])}`"
                   + (f" — {md(ver)}" if ver else ""))

    doc.append("")
    doc.append("## Skipped entries")
    doc.append("")
    for n, why in SKIPPED:
        doc.append(f"- `{md(n)}` — {md(why)}")

    os.makedirs(os.path.dirname(REPORT_PATH), exist_ok=True)
    with open(REPORT_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(doc) + "\n")
    print(f"\nreport saved to {REPORT_PATH}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

/*
 * The round-trip guest of the ABI test suite (world abi_selftest).
 *
 * selftest_run_imports calls every import of abi_test and eden_core with
 * known values and counts wrong answers; the other exports take every
 * export argument type. eden_init / eden_step also exercise eden_asset,
 * eden_video (three formats and the palette), eden_input and eden_audio,
 * so tests/eden/test_abi.das can check what the headless host recorded.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "eden/abi_selftest.h"

static int mismatches;

static void expect(int ok, const char *what) {
    if (!ok) {
        mismatches++;
        eden_core_log_z(EDEN_CORE_LOG_ERROR, what);
    }
}

int32_t selftest_run_imports(void) {
    mismatches = 0;
    expect(abi_test_echo_i32(-7) == -7, "echo_i32");
    expect(abi_test_echo_i32(ABI_TEST_MAGIC) == ABI_TEST_MAGIC, "echo_i32 magic");
    expect(abi_test_echo_i64(-5000000000000LL) == -5000000000000LL, "echo_i64");
    expect(abi_test_echo_f32(1.5f) == 1.5f, "echo_f32");
    expect(abi_test_echo_f64(-2.25) == -2.25, "echo_f64");
    expect(abi_test_negate(1) == 0 && abi_test_negate(0) == 1, "negate");
    expect(abi_test_mix(1, 2, 0.5f, 0.25, 1) == 4.75, "mix");
    expect(abi_test_str_len_z("hello") == 5, "str_len");
    expect(abi_test_str_len("", 0) == 0, "str_len empty");
    static const uint8_t bytes[4] = {1, 2, 3, 250};
    expect(abi_test_bytes_sum(bytes, 4) == 256, "bytes_sum");
    uint8_t out[8];
    memset(out, 0, sizeof out);
    expect(abi_test_fill(out, 8, 254) == 8, "fill count");
    expect(out[0] == 254 && out[1] == 255 && out[2] == 0 && out[7] == 5, "fill bytes");
    int32_t h1 = abi_test_make_handle(11);
    int32_t h2 = abi_test_make_handle(22);
    expect(h1 > 0 && h2 > 0 && h1 != h2, "make_handle");
    expect(abi_test_handle_value(h1) == 11 && abi_test_handle_value(h2) == 22, "handle_value");
    expect(abi_test_handle_value(0) == -1 && abi_test_handle_value(9999) == -1, "handle_value bad");
    int64_t t0 = eden_core_time_us();
    int64_t t1 = eden_core_time_us();
    expect(t0 >= 0 && t1 >= t0, "time_us monotonic");
    printf("selftest: printf %d %s %05.2f %x %llu|%-4s|\n", -12, "str", 3.14159, 255u, 18446744073709551615ULL, "ab");
    abi_test_record_z("imports done");
    return mismatches;
}

int32_t selftest_take_str(const char *s, int32_t s_len) {
    return s_len + (s_len > 0 ? 1000 * (unsigned char)s[0] : 0);
}

int32_t selftest_take_bytes(const void *b, int32_t b_len) {
    const uint8_t *p = (const uint8_t *)b;
    int32_t sum = 0;
    for (int32_t i = 0; i < b_len; i++) {
        sum += p[i];
    }
    return sum;
}

double selftest_scalars(int32_t a, int64_t b, float c, double d, int32_t e) {
    return (double)a + (double)b + (double)c + d + (e ? 1.0 : 0.0);
}

int64_t selftest_i64(int64_t v) {
    return v * 3;
}

float selftest_f32(float v) {
    return v * 0.5f;
}

int32_t selftest_trap(void) {
    abi_test_fail();
    return 1; /* not reached: the host traps */
}

int32_t selftest_bad_pointer(int32_t which) {
    static const char with_nul[3] = {'a', 0, 'b'};
    if (which == 0) {
        return abi_test_str_len((const char *)(uintptr_t)0x7ffffff0u, 64);
    }
    if (which == 1) {
        return abi_test_bytes_sum((const void *)(uintptr_t)16u, -1);
    }
    if (which == 2) {
        return abi_test_str_len(with_nul, 3);
    }
    return -1;
}

int32_t selftest_storage(void) {
    mismatches = 0;
    uint8_t buf[128];
    /* the raw API */
    eden_storage_remove_z("save1");
    expect(eden_storage_size_z("save1") == EDEN_STORAGE_ERR_NOT_FOUND, "storage size missing");
    for (int i = 0; i < 100; i++) {
        buf[i] = (uint8_t)(i * 3);
    }
    expect(eden_storage_write_z("save1", buf, 100) == EDEN_STORAGE_OK, "storage write");
    expect(eden_storage_size_z("save1") == 100, "storage size");
    memset(buf, 0, sizeof buf);
    expect(eden_storage_read_z("save1", 10, buf, 20) == 20 && buf[0] == 30 && buf[19] == 87, "storage read range");
    expect(eden_storage_read_z("save1", 95, buf, 20) == 5 && buf[4] == (uint8_t)(99 * 3), "storage read at the end");
    expect(eden_storage_read_z("save1", 101, buf, 20) == EDEN_STORAGE_ERR_RANGE, "storage read past the end");
    expect(eden_storage_read_z("save1", -1, buf, 20) == EDEN_STORAGE_ERR_RANGE, "storage read negative offset");
    expect(eden_storage_write("", 0, buf, 1) == EDEN_STORAGE_ERR_NAME, "storage empty name");
    static const char long_name[] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; /* 65 */
    expect(eden_storage_size_z(long_name) == EDEN_STORAGE_ERR_NAME, "storage long name");
    expect(eden_storage_write_z("save1", buf, 3) == EDEN_STORAGE_OK && eden_storage_size_z("save1") == 3, "storage replace");
    expect(eden_storage_remove_z("save1") == EDEN_STORAGE_OK, "storage remove");
    expect(eden_storage_remove_z("save1") == EDEN_STORAGE_ERR_NOT_FOUND, "storage remove twice");
    /* the libc on top */
    FILE *f = fopen("notes.txt", "w");
    expect(f != NULL, "fopen w");
    if (f) {
        fprintf(f, "level %d\n", 3);
        expect(eden_storage_size_z("notes.txt") < 0, "nothing written before fclose");
        expect(fclose(f) == 0, "fclose w");
    }
    expect(eden_storage_size_z("notes.txt") == 8, "fclose wrote the blob");
    f = fopen("notes.txt", "a");
    if (f) {
        fputs("score 9\n", f);
        fclose(f);
    }
    f = fopen("notes.txt", "rb");
    expect(f != NULL, "fopen r of a blob");
    if (f) {
        size_t got = fread(buf, 1, sizeof buf, f);
        fclose(f);
        expect(got == 16 && memcmp(buf, "level 3\nscore 9\n", 16) == 0, "append kept the old content");
    }
    expect(remove("notes.txt") == 0 && fopen("notes.txt", "r") == NULL, "remove");
    f = fopen("keep", "wb");
    if (f) {
        fwrite("keep!", 1, 5, f);
        fclose(f);
    }
    expect(eden_storage_size_z("keep") == 5, "keep written");
    return mismatches;
}

int32_t selftest_blob_size(const char *name, int32_t name_len) {
    return eden_storage_size(name, name_len);
}

int32_t selftest_reenter(void) {
    abi_test_record_z("reenter");
    return 7;
}

/* ---- the eden_game exports ---------------------------------------------- */

int32_t eden_abi_version(void) {
    return EDEN_GAME_VERSION;
}

static int32_t stream;
static int step_count;
static int32_t asset_sum;

int32_t eden_init(void) {
    int32_t size = eden_asset_size_z("data");
    if (size < 0) {
        eden_core_log_z(EDEN_CORE_LOG_ERROR, "asset `data` missing");
        return 1;
    }
    FILE *f = fopen("data", "rb");
    if (!f) {
        return 2;
    }
    uint8_t chunk[3];
    size_t got;
    asset_sum = 0;
    while ((got = fread(chunk, 1, sizeof chunk, f)) > 0) {
        for (size_t i = 0; i < got; i++) {
            asset_sum += chunk[i];
        }
    }
    fseek(f, -1, SEEK_END);
    long last = ftell(f);
    fclose(f);
    if (last != size - 1) {
        return 3;
    }
    if (fopen("data", "r+") != NULL || fopen("nope", "rb") != NULL) {
        return 4;
    }
    stream = eden_audio_open(22050, 2);
    if (stream <= 0) {
        return 5;
    }
    if (eden_audio_open(7, 2) != EDEN_AUDIO_ERR_ARGS) {
        return 6;
    }
    printf("init: asset sum %d\n", (int)asset_sum);
    return 0;
}

/* one frame per step, in turn RGBA8, RGB565 and INDEXED8; the pixel values
 * depend on the input buttons, so the host test can see input arrive */
int32_t eden_step(int32_t budget_us) {
    (void)budget_us;
    enum { W = 4, H = 2 };
    int32_t buttons = eden_input_buttons(0);
    int32_t kind = step_count % 3;
    int32_t r;
    if (kind == 0) {
        uint8_t px[W * H * 4];
        for (int i = 0; i < W * H; i++) {
            px[i * 4 + 0] = (uint8_t)(i * 10 + buttons);
            px[i * 4 + 1] = (uint8_t)(asset_sum);
            px[i * 4 + 2] = 200;
            px[i * 4 + 3] = 255;
        }
        r = eden_video_present(px, sizeof px, W, H, W * 4, EDEN_VIDEO_FORMAT_RGBA8);
    } else if (kind == 1) {
        /* stride larger than a row, last row short: allowed */
        uint16_t px[6 * H];
        for (int i = 0; i < 6 * H; i++) {
            px[i] = (uint16_t)(0xF800u | (unsigned)buttons);
        }
        r = eden_video_present(px, (6 * (H - 1) + W) * 2, W, H, 6 * 2, EDEN_VIDEO_FORMAT_RGB565);
    } else {
        uint8_t pal[3 * 4] = {0, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255};
        if (eden_video_set_palette(pal, sizeof pal) != EDEN_VIDEO_OK) {
            return EDEN_GAME_STEP_ERROR;
        }
        uint8_t px[W * H];
        for (int i = 0; i < W * H; i++) {
            px[i] = (uint8_t)(i % 3);
        }
        r = eden_video_present(px, sizeof px, W, H, W, EDEN_VIDEO_FORMAT_INDEXED8);
    }
    if (r != EDEN_VIDEO_OK) {
        return EDEN_GAME_STEP_ERROR;
    }
    /* rejected frames must not count */
    if (eden_video_present(0, 0, W, H, W * 4, 99) != EDEN_VIDEO_ERR_FORMAT) {
        return EDEN_GAME_STEP_ERROR;
    }
    int16_t samples[2 * 64];
    for (int i = 0; i < 2 * 64; i++) {
        samples[i] = (int16_t)(i * 100 - 3000);
    }
    if (eden_audio_push(stream, samples, sizeof samples, EDEN_AUDIO_SAMPLE_S16) != 64) {
        return EDEN_GAME_STEP_ERROR;
    }
    if (eden_audio_push(stream, samples, 3, EDEN_AUDIO_SAMPLE_S16) != EDEN_AUDIO_ERR_ARGS) {
        return EDEN_GAME_STEP_ERROR;
    }
    if (eden_input_key_down(0x1e) != (buttons != 0) || eden_input_key_down(0) != 0 || eden_input_key_down(4096) != 0) {
        return EDEN_GAME_STEP_ERROR;
    }
    step_count++;
    return EDEN_GAME_STEP_FRAME | (step_count >= 3 ? EDEN_GAME_STEP_QUIT : 0);
}

void eden_shutdown(void) {
    eden_audio_close(stream);
    stream = 0;
}

/* the snapshot: step count and asset sum */
int32_t eden_state_size(void) {
    return 8;
}

int32_t eden_state_save(int32_t dst, int32_t cap) {
    if (cap < 8) {
        return -1;
    }
    int32_t v[2] = {step_count, asset_sum};
    memcpy((void *)(uintptr_t)dst, v, 8);
    return 8;
}

int32_t eden_state_load(const void *snapshot, int32_t snapshot_len) {
    if (snapshot_len != 8) {
        return -1;
    }
    int32_t v[2];
    memcpy(v, snapshot, 8);
    step_count = v[0];
    asset_sum = v[1];
    return 0;
}
